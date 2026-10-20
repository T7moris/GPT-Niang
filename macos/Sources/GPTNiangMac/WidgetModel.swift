import AppKit
import Combine
import GPTNiangCore
import GPTNiangUpdate
import Darwin
import os

private struct QuotaWorkerRecord: Decodable {
    let token: String
    let pid: Int32
    let parentPid: Int32
    let at: Double?
    let version: String?
    let busy: Bool?
    let handoffProtocol: Int?
    var validIdentity: Bool { !token.isEmpty && pid > 0 && parentPid >= 0 }
}

private struct WorkerStopRequest: Equatable {
    let seconds: Int
    let nanoseconds: Int
    let contents: Data
}

@MainActor
final class WidgetModel: ObservableObject {
    @Published var snapshot = UsageSnapshot()
    @Published var message: String?
    @Published var bubble = false
    @Published var sceneStarted = Date()
    @Published var colorMode: ColorMode
    @Published var fullChance: Double
    @Published var textChance: Double
    @Published var colorPaused: Bool
    @Published var colorScope: ColorScope = .none
    @Published var specialQuotes: String
    @Published var language: InterfaceLanguage
    @Published var bubbleTapAdvance: Bool
    @Published var displayScale = 1.0
    @Published var scale: Double
    @Published var volume: Double
    @Published var loginRequested: Bool
    @Published var followCodex: Bool
    @Published var desktopTopmost: Bool
    @Published var desktopLeft: Double?
    @Published var desktopBottom: Double?
    @Published var soundOn: Bool
    @Published var hideMenu: Bool
    @Published var completionEnabled = false
    @Published var isCompletionMessage = false
    var onManualBubble: (() -> Void)?
    @Published var facingLeft = false
    var desktopNeedsMigration = false
    @Published var x: Double
    @Published var y: Double
    @Published var quoteText = ""
    @Published var settingsError: String?
    @Published var refreshing = false
    @Published var trackingNote: String?
    var interactionActive = false
    let dataDirectory: URL
    let resources: URL
    private let backendVersion: String?
    let characterImage: NSImage?
    let defaults: UserDefaults
    private var worker: Process?
    private var lastWorkerStart = -Double.infinity
    private var lastWorkerCheck: TimeInterval?
    private var workerUnhealthySince: TimeInterval?
    private var workerReportedHeartbeat = false
    private var workerRecoveryPending = false
    private var workerRecoveryAvailable = true
    private var initialStopRequest: WorkerStopRequest?
    private var workerHandoff: (pid: Int32, token: String, legacyRequest: WorkerStopRequest?)?
    var workerRunning: Bool { worker?.isRunning == true }
    var updateIdle: Bool { updateIsIdle() }
    func updateIsIdle(now: Date = Date(), isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) -> Bool {
        guard workerHandoff == nil, !workerRecoveryPending, !refreshing, !interactionActive, !audio.busy else { return false }
        if let request = readStopRequest(), request != initialStopRequest { return false }
        let owner: QuotaWorkerRecord?, status: QuotaWorkerRecord?
        do {
            owner = try workerRecord("worker.lock"); status = try workerRecord("worker-status.json")
        } catch { return false } // Unreadable or malformed state is not evidence of idleness.
        if let owner, !owner.validIdentity { return false }
        if let status, !status.validIdentity { return false }
        if let worker, worker.isRunning {
            guard let record = liveWorker(owner: owner, status: status, isAlive: isAlive),
                  record.pid == worker.processIdentifier else { return false }
            return record.busy == false && freshWorker(record, now: now)
        }
        if let owner, isAlive(owner.pid) {
            guard let record = liveWorker(owner: owner, status: status, isAlive: isAlive) else { return false }
            return record.busy == false && freshWorker(record, now: now)
        }
        // Dead records must not block updates, but a live orphan heartbeat is unknown state.
        return status.map { !isAlive($0.pid) } ?? true
    }
    private var stderr: FileHandle?
    private var timer: Timer?
    private var quotes: [Quote] = []
    lazy var audio = WidgetAudio(data: dataDirectory, resources: resources,
        node: { [weak self] in self?.findNode() }, enabled: { [weak self] in self?.soundOn == true },
        volume: { [weak self] in self?.volume ?? 0 }, text: { [weak self] in self?.text($0) ?? $0 })
    private var lastQuote: String?
    private var quoteGeneration = 0
    private var refreshUntil = Date.distantPast
    private var lastStatusData: Data?
    private var lastChecked: Double?
    private let logger = Logger(subsystem: "io.github.t7moris.GPTNiangMac", category: "worker")

    init(dataDirectory: URL, resources: URL) {
        self.dataDirectory = dataDirectory; self.resources = resources
        let manifest = resources.appendingPathComponent("Backend/.codex-plugin/plugin.json")
        let metadata = (try? Data(contentsOf: manifest)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        backendVersion = metadata?["version"] as? String
        characterImage = NSImage(contentsOf: resources.appendingPathComponent("gpt-dragon-niang-bust.png"))
        // Keep preferences together with quota state; no shared Codex config edits.
        let prefs = dataDirectory.appendingPathComponent("preferences.json")
        let values = (try? Data(contentsOf: prefs)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        language = InterfaceLanguage(rawValue: values["language"] as? String ?? "system") ?? .system
        defaults = .standard
        colorMode = ColorMode(rawValue: values["colorMode"] as? String ?? "mixed") ?? .mixed
        fullChance = min(100, max(0, values["fullChance"] as? Double ?? 0.5))
        textChance = min(100, max(0, values["textChance"] as? Double ?? 3))
        colorPaused = values["colorPaused"] as? Bool ?? false
        specialQuotes = values["specialQuotes"] as? String ?? "Token来，Token来"
        bubbleTapAdvance = values["bubbleTapAdvance"] as? Bool ?? false
        scale = min(2.5, max(0.6, values["scale"] as? Double ?? 1))
        volume = min(1, max(0, values["volume"] as? Double ?? 0.9))
        loginRequested = values["loginRequested"] as? Bool ?? false
        followCodex = values["followCodex"] as? Bool ?? true
        desktopTopmost = values["desktopTopmost"] as? Bool ?? false
        desktopLeft = values["desktopLeft"] as? Double
        desktopBottom = values["desktopBottom"] as? Double
        soundOn = values["soundOn"] as? Bool ?? true
        hideMenu = values["hideMenu"] as? Bool ?? false
        completionEnabled = values["taskCompletionBubble"] as? Bool ?? false
        x = min(1, max(0, values["x"] as? Double ?? 1))
        y = min(1, max(0, values["y"] as? Double ?? 0))
        desktopNeedsMigration = !followCodex && desktopLeft == nil && values["layoutVersion"] == nil && !values.isEmpty
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path)
        } catch { settingsError = text("無法建立本機資料目錄：%@", String(describing: error.localizedDescription)) }
        initialStopRequest = readStopRequest()
        loadQuotes()
        snapshot = UsageSnapshot(error: text("正在讀取目前帳戶的額度…"))
    }

    func text(_ key: String, _ args: String...) -> String { language.text(key, arguments: args) }

    func start() {
        startWorker()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil; audio.stop()
        writePresence(visible: false)
        if let worker, worker.isRunning { worker.terminate() }; worker = nil
        try? stderr?.close(); stderr = nil
    }
    func tick(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let file = dataDirectory.appendingPathComponent("status.json")
        if let data = try? Data(contentsOf: file) {
            readSnapshot(data)
        } else if lastStatusData != nil {
            lastStatusData = nil; snapshot = UsageSnapshot(error: text("正在讀取目前帳戶的額度…"))
        }
        if Date() > refreshUntil { refreshing = false }
        guard settleWorkerHandoff() else { return }
        if let request = readStopRequest(), request != initialStopRequest {
            if let worker, worker.isRunning { worker.terminate() }
            return
        }
        if worker?.isRunning == true { checkOwnedWorker(now: now) }
        else { startWorker(now: now) }
    }
    func readSnapshot(_ data: Data) {
            if data != lastStatusData {
                lastStatusData = data
                snapshot = (try? JSONDecoder().decode(UsageSnapshot.self, from: data)) ?? UsageSnapshot(error: text("额度数据无法读取，请刷新。"))
                let checked = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["checkedAt"] as? Double
                if checked != lastChecked { lastChecked = checked; refreshing = false }
            }
    }
    private func workerRecord(_ name: String) throws -> QuotaWorkerRecord? {
        do {
            let data = try Data(contentsOf: dataDirectory.appendingPathComponent(name))
            return try JSONDecoder().decode(QuotaWorkerRecord.self, from: data)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
            throw error
        }
    }
    private func liveWorker(owner: QuotaWorkerRecord?, status: QuotaWorkerRecord?,
                            isAlive: (Int32) -> Bool) -> QuotaWorkerRecord? {
        guard let owner, let status, owner.validIdentity, status.validIdentity,
              status.token == owner.token, status.pid == owner.pid, status.parentPid == owner.parentPid,
              isAlive(owner.pid), owner.parentPid == 0 || isAlive(owner.parentPid) else { return nil }
        return status
    }
    private func freshWorker(_ status: QuotaWorkerRecord, now: Date) -> Bool {
        guard let at = status.at, at.isFinite else { return false }
        let age = now.timeIntervalSince1970 * 1000 - at
        return age >= 0 && age < 5000
    }
    func workerHealthy(version: String, now: Date = Date(),
                       isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) -> Bool {
        guard !version.isEmpty, backendVersion == version,
              let status = liveWorker(owner: try? workerRecord("worker.lock"),
                                      status: try? workerRecord("worker-status.json"), isAlive: isAlive),
              status.version == version else { return false }
        return freshWorker(status, now: now)
    }
    private func checkOwnedWorker(now: TimeInterval) {
        guard let worker, worker.isRunning, !workerRecoveryPending else { return }
        // A pause of the GUI/timer (including sleep) is not a continuous outage.
        let gap = lastWorkerCheck.map { now - $0 }
        lastWorkerCheck = now.isFinite ? now : nil
        if !(gap.map { $0 >= 0 && $0 <= 3 } ?? false) { workerUnhealthySince = nil }
        guard now.isFinite else { return }
        if let status = liveWorker(owner: try? workerRecord("worker.lock"),
                                   status: try? workerRecord("worker-status.json"),
                                   isAlive: { kill($0, 0) == 0 || errno == EPERM }),
           status.pid == worker.processIdentifier, status.parentPid == getpid(),
           freshWorker(status, now: Date()) {
            // Query success, busy state and bundle version do not define liveness.
            workerReportedHeartbeat = true; workerUnhealthySince = nil
            workerRecoveryAvailable = true
            return
        }
        if workerUnhealthySince == nil { workerUnhealthySince = now }
        let grace: TimeInterval = workerReportedHeartbeat ? 10 : 30
        guard workerRecoveryAvailable, now - (workerUnhealthySince ?? now) >= grace else { return }
        // Only the Process created by this GUI is signalled. Wait for its exit;
        // no foreign PID, lock removal or SIGKILL fallback is used.
        workerRecoveryPending = true; workerRecoveryAvailable = false
        lastWorkerStart = now
        worker.terminate()
        logger.error("Owned quota worker lost its heartbeat; requested one recovery")
    }
    private func readStopRequest(_ source: URL? = nil) -> WorkerStopRequest? {
        let file = source ?? dataDirectory.appendingPathComponent("stop.flag")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var before = stat(), after = stat()
        guard fstat(handle.fileDescriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG, before.st_size > 0, before.st_size <= 4096,
              let data = try? handle.read(upToCount: 4097), data.count == Int(before.st_size),
              fstat(handle.fileDescriptor, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { return nil }
        return WorkerStopRequest(seconds: Int(before.st_mtimespec.tv_sec),
                                 nanoseconds: Int(before.st_mtimespec.tv_nsec), contents: data)
    }
    private func settleWorkerHandoff() -> Bool {
        guard let handoff = workerHandoff else { return true }
        let current = readStopRequest()
        if let legacy = handoff.legacyRequest {
            guard current == legacy else { workerHandoff = nil; return true }
        } else if let current, current != initialStopRequest {
            workerHandoff = nil; return true
        }
        let owner: QuotaWorkerRecord?
        do { owner = try workerRecord("worker.lock") } catch { return false }
        if let owner {
            guard owner.validIdentity else { return false }
            if owner.token == handoff.token {
                guard owner.pid == handoff.pid else { return false }
                if kill(handoff.pid, 0) == 0 || errno == EPERM { return false }
            }
        }
        if let legacy = handoff.legacyRequest { initialStopRequest = legacy }
        workerHandoff = nil; return true
    }
    private func waitForSharedWorker(now: TimeInterval) -> Bool {
        guard let owner = try? workerRecord("worker.lock"), owner.validIdentity,
              kill(owner.pid, 0) == 0 || errno == EPERM else { return false }
        guard UUID(uuidString: owner.token) != nil else { return false }
        // A live GUI keeps its writer. Busy, stale or unknown state waits without contenders.
        guard owner.parentPid == 0, let backendVersion, !backendVersion.isEmpty,
              let status = try? workerRecord("worker-status.json"),
              let record = liveWorker(owner: owner, status: status, isAlive: { kill($0, 0) == 0 || errno == EPERM }),
              record.busy == false, freshWorker(record, now: Date()),
              now - lastWorkerStart >= 5 else { return true }
        guard let installed = StableVersion(backendVersion), record.handoffProtocol == nil || record.handoffProtocol == 1 else { return true }
        if let version = record.version {
            guard let previous = StableVersion(version), previous < installed else { return true }
        } else if record.handoffProtocol != nil { return true }
        let modern = record.handoffProtocol == 1
        let file = dataDirectory.appendingPathComponent(modern ? "worker-handoff-" + owner.token + ".flag" : "stop.flag")
        // Never replace another stop request. A private request already targets this same owner.
        if FileManager.default.fileExists(atPath: file.path) {
            if modern, readStopRequest(file) != nil {
                lastWorkerStart = now; workerHandoff = (owner.pid, owner.token, nil)
            }
            return true
        }
        guard let latest = try? workerRecord("worker.lock"), latest.token == owner.token,
              latest.pid == owner.pid, latest.parentPid == 0 else { return true }
        let descriptor = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return true }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        lastWorkerStart = now
        let data = Data(("worker-handoff:" + owner.token + ":" + UUID().uuidString).utf8)
        do {
            try handle.write(contentsOf: data)
            if modern { workerHandoff = (owner.pid, owner.token, nil) }
            else if let request = readStopRequest(file), request.contents == data { workerHandoff = (owner.pid, owner.token, request) }
        } catch { logger.error("Quota worker handoff request could not be written") }
        return true
    }
    private func startWorker(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard worker?.isRunning != true, settleWorkerHandoff() else { return }
        // Preserve requests from this GUI session; reopening the app can resume.
        if let request = readStopRequest(), request != initialStopRequest { return }
        // Reuse an initialized writer of this bundle version instead of spawning contenders.
        if let backendVersion, workerHealthy(version: backendVersion) {
            workerRecoveryPending = false
            return
        }
        if waitForSharedWorker(now: now) { return }
        // Keep per-second state reads; only failed process starts receive a cooldown.
        guard now - lastWorkerStart >= 5 else { return }
        lastWorkerStart = now
        worker = nil
        lastWorkerCheck = nil; workerUnhealthySince = nil; workerReportedHeartbeat = false
        workerRecoveryPending = false
        try? stderr?.close(); stderr = nil
        guard let node = findNode() else {
            snapshot = UsageSnapshot(error: text("找不到 Node.js 20+。請先安裝 Node.js，再重新開啟 GPT 娘。"))
            return
        }
        let backend = resources.appendingPathComponent("Backend")
        let configURL = dataDirectory.appendingPathComponent("installation.json")
        do {
            let saved = (try? Data(contentsOf: configURL))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let configured = saved?["codexPath"] as? String ?? "codex"
            let codexPath = configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "codex" : configured
            try writeJSON(["dataDir": dataDirectory.path, "nodePath": node.path, "codexPath": codexPath], to: configURL)
            let log = dataDirectory.appendingPathComponent("worker.log")
            // Only the last worker startup's sanitized errors are useful.
            try Data().write(to: log, options: .atomic)
            stderr = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = node
            process.arguments = [backend.appendingPathComponent("runtime/watch.mjs").path, configURL.path, String(ProcessInfo.processInfo.processIdentifier), "--inherit-stop"]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
            process.standardError = stderr
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = [node.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
            process.environment = env
            try process.run(); worker = process
            lastWorkerCheck = now; workerUnhealthySince = now
            logger.info("Quota worker started")
        } catch { snapshot = UsageSnapshot(error: text("額度背景程序無法啟動：%@", String(describing: error.localizedDescription))) }
    }
    func findNode() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let candidates = [env["GPT_NIANG_NODE"], resources.appendingPathComponent("node").path,
                          "/opt/homebrew/opt/node@22/bin/node", "/opt/homebrew/bin/node", "/usr/local/bin/node"]
            .compactMap { $0 } + (env["PATH"] ?? "").split(separator: ":").map { String($0) + "/node" }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    func refresh(renewBubble: Bool = false) {
        refreshing = true; refreshUntil = Date().addingTimeInterval(22)
        if renewBubble && bubble && message == nil { restartTTL(delay: 0) }
        requestRefreshFlag()
    }
    func hideBubble() { onManualBubble?(); isCompletionMessage = false; quoteGeneration += 1; bubble = false; updateAppearance() }
    func toggleQuota() {
        if bubble && message == nil { hideBubble() } else { showQuota() }
    }
    func resetPosition() {
        if followCodex { x = 1; y = 0 } else { desktopLeft = nil; desktopBottom = nil }
        hideBubble(); savePreferences()
    }
    func writePresence(visible: Bool) {
        try? writeJSON(["visible": visible, "at": Date().timeIntervalSince1970 * 1000,
                        "pid": ProcessInfo.processInfo.processIdentifier], to: dataDirectory.appendingPathComponent("presence.json"))
    }
    func savePreferences() {
        let file = dataDirectory.appendingPathComponent("preferences.json")
        var values = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let current: [String: Any] = ["layoutVersion": 2, "scale": scale, "volume": volume, "followCodex": followCodex, "loginRequested": loginRequested, "x": x, "y": y,
            "colorMode": colorMode.rawValue, "fullChance": fullChance, "textChance": textChance, "colorPaused": colorPaused,
            "specialQuotes": specialQuotes, "bubbleTapAdvance": bubbleTapAdvance, "language": language.rawValue,
            "desktopTopmost": desktopTopmost, "soundOn": soundOn, "hideMenu": hideMenu, "taskCompletionBubble": completionEnabled]
        values.merge(current) { _, new in new }
        values["desktopLeft"] = desktopLeft; values["desktopBottom"] = desktopBottom
        try? writeJSON(values, to: file)
    }
    func migrateDesktopPosition(area: CGRect, size: CGSize) {
        guard desktopNeedsMigration else { return }
        let frame = WidgetPlacement.frame(host: area, visibleScreen: area, size: size, x: x, y: y)
        desktopLeft = frame.minX; desktopBottom = frame.minY
        desktopNeedsMigration = false; savePreferences()
    }
    func showQuota() {
        onManualBubble?(); isCompletionMessage = false
        let opening = !bubble
        let switching = message != nil
        message = nil; bubble = true
        updateAppearance()
        restartTTL(delay: opening ? 0.52 : switching ? 0.28 : 0)
        if opening { requestRefreshFlag() }
    }
    func characterClick() {
        if bubble && bubbleTapAdvance { clickBubble() } else { showQuota() }
    }
    private func requestRefreshFlag() {
        try? Data(UUID().uuidString.utf8).write(to: dataDirectory.appendingPathComponent("refresh.flag"), options: .atomic)
    }
    func showQuote() {
        onManualBubble?(); isCompletionMessage = false
        let opening = !bubble
        loadQuotes()
        message = QuoteFile.choose(quotes, excluding: lastQuote) ?? "我在這裡，慢慢來就好。"
        lastQuote = message; bubble = true
        updateAppearance()
        restartTTL(delay: opening ? 0.52 : 0.28)
    }
    func showCompletion() {
        quoteGeneration += 1; isCompletionMessage = true
        message = "Codex\n" + text("有回复已结束"); bubble = true
        colorScope = .none; sceneStarted = Date().addingTimeInterval(0.52)
    }
    func hideCompletion() {
        guard isCompletionMessage else { return }
        quoteGeneration += 1; bubble = false; isCompletionMessage = false; updateAppearance()
    }
    func updateAppearance() {
        colorScope = Appearance.scope(mode: colorMode, quote: bubble ? message : nil,
                                      special: specialQuotes.components(separatedBy: "\n"),
                                      fullChance: fullChance, textChance: textChance, draw: Double.random(in: 0..<1))
    }
    private func restartTTL(delay: Double) {
        quoteGeneration += 1
        sceneStarted = Date().addingTimeInterval(delay)
        let generation = quoteGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 5) { [weak self] in
            guard let self, self.quoteGeneration == generation else { return }
            self.bubble = false; self.updateAppearance()
        }
    }
    func clickBubble() {
        onManualBubble?(); isCompletionMessage = false
        if message == nil { showQuote() } else { quoteGeneration += 1; bubble = false; updateAppearance() }
    }
    func loadQuotes() {
        let builtin = (try? Data(contentsOf: resources.appendingPathComponent("quotes.json"))).flatMap { try? QuoteFile.decode($0) } ?? []
        let file = dataDirectory.appendingPathComponent("quotes.json")
        if FileManager.default.fileExists(atPath: file.path) {
            if let data = try? Data(contentsOf: file), let custom = try? QuoteFile.decode(data), !custom.isEmpty { quotes = custom }
            else { quotes = builtin; settingsError = text("自訂語錄無法讀取，暫時使用內建語錄。") }
        } else { quotes = builtin }
        quoteText = QuoteFile.editorText(quotes)
    }
    func saveQuotes() {
        let rows = QuoteFile.editorQuotes(quoteText)
        guard !rows.isEmpty, rows.allSatisfy(\.valid) else { settingsError = text("每行一則語錄，每則最多 200 字，至少保留一則。"); return }
        do {
            try backupQuotes()
            try writeJSON(["version": 1, "quotes": rows.map { ["text": $0.text, "weight": $0.weight] as [String: Any] }],
                          to: dataDirectory.appendingPathComponent("quotes.json"))
            quotes = rows; settingsError = nil
        } catch { settingsError = error.localizedDescription }
    }
    private func backupQuotes() throws {
        let file = dataDirectory.appendingPathComponent("quotes.json")
        if FileManager.default.fileExists(atPath: file.path) {
            try Data(contentsOf: file).write(to: dataDirectory.appendingPathComponent("quotes.json.bak"), options: .atomic)
        }
    }
    func resetQuotes() {
        do {
            try backupQuotes()
            let file = dataDirectory.appendingPathComponent("quotes.json")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            loadQuotes()
        } catch { settingsError = error.localizedDescription }
    }
    func play(_ name: String) {
        audio.play(name)
    }
    private func writeJSON(_ values: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
    }
}
