import AppKit
import Combine
import GPTNiangCore
import os

@MainActor
final class WidgetModel: ObservableObject {
    @Published var alertPreferences = AlertPreferences()
    @Published var alertPermissionDenied = false
    @Published var alertMonitorError: String?
    @Published var alertStorageError: String?
    lazy var alerts = AlertCoordinator(model: self)
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
    let characterImage: NSImage?
    let defaults: UserDefaults
    private var worker: Process?
    var workerRunning: Bool { worker?.isRunning == true }
    var updateIdle: Bool {
        guard !refreshing, !interactionActive else { return false }
        let file = dataDirectory.appendingPathComponent("worker-status.json")
        let status = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return status?["busy"] as? Bool != true
    }
    private var stderr: FileHandle?
    private var timer: Timer?
    private var quotes: [Quote] = []
    private var sounds: [NSSound] = []
    private var lastQuote: String?
    private var quoteGeneration = 0
    private var refreshUntil = Date.distantPast
    private var lastStatusData: Data?
    private var lastChecked: Double?
    private let logger = Logger(subsystem: "io.github.t7moris.GPTNiangMac", category: "worker")

    init(dataDirectory: URL, resources: URL) {
        self.dataDirectory = dataDirectory; self.resources = resources
        characterImage = NSImage(contentsOf: resources.appendingPathComponent("gpt-dragon-niang-bust.png"))
        // Keep preferences together with quota state; no shared Codex config edits.
        let prefs = dataDirectory.appendingPathComponent("preferences.json")
        let values = (try? Data(contentsOf: prefs)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if let raw = values["alerts"], let data = try? JSONSerialization.data(withJSONObject: raw),
           var decoded = try? JSONDecoder().decode(AlertPreferences.self, from: data) {
            decoded.validate(); alertPreferences = decoded
        }
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
        x = min(1, max(0, values["x"] as? Double ?? 1))
        y = min(1, max(0, values["y"] as? Double ?? 0))
        desktopNeedsMigration = !followCodex && desktopLeft == nil && values["layoutVersion"] == nil && !values.isEmpty
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path)
            try? FileManager.default.removeItem(at: dataDirectory.appendingPathComponent("stop.flag"))
        } catch { settingsError = text("無法建立本機資料目錄：%@", String(describing: error.localizedDescription)) }
        loadQuotes()
        snapshot = UsageSnapshot(error: text("正在讀取目前帳戶的額度…"))
    }

    func text(_ key: String, _ args: String...) -> String { language.text(key, arguments: args) }

    func start() {
        startWorker()
        alerts.configure()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    func stop() {
        alerts.stop()
        timer?.invalidate(); timer = nil
        writePresence(visible: false)
        worker?.terminate(); worker = nil
        try? stderr?.close(); stderr = nil
    }
    func tick() {
        let file = dataDirectory.appendingPathComponent("status.json")
        if let data = try? Data(contentsOf: file) {
            readSnapshot(data)
        } else if lastStatusData != nil {
            lastStatusData = nil; snapshot = UsageSnapshot(error: text("正在讀取目前帳戶的額度…"))
        }
        if Date() > refreshUntil { refreshing = false }
        if worker?.isRunning != true { startWorker() }
        alerts.tick()
    }
    func readSnapshot(_ data: Data) {
            if data != lastStatusData {
                lastStatusData = data
                snapshot = (try? JSONDecoder().decode(UsageSnapshot.self, from: data)) ?? UsageSnapshot(error: text("额度数据无法读取，请刷新。"))
                let checked = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["checkedAt"] as? Double
                if checked != lastChecked { lastChecked = checked; refreshing = false }
            }
    }
    private func startWorker() {
        guard worker?.isRunning != true else { return }
        guard let node = findNode() else {
            snapshot = UsageSnapshot(error: text("找不到 Node.js 20+。請先安裝 Node.js，再重新開啟 GPT 娘。"))
            return
        }
        let backend = resources.appendingPathComponent("Backend")
        let configURL = dataDirectory.appendingPathComponent("installation.json")
        do {
            try writeJSON(["dataDir": dataDirectory.path, "nodePath": node.path, "codexPath": "codex"], to: configURL)
            let log = dataDirectory.appendingPathComponent("worker.log")
            // Only the last worker startup's sanitized errors are useful.
            try Data().write(to: log, options: .atomic)
            stderr = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = node
            process.arguments = [backend.appendingPathComponent("runtime/watch.mjs").path, configURL.path, String(ProcessInfo.processInfo.processIdentifier)]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
            process.standardError = stderr
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = [node.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
            process.environment = env
            try process.run(); worker = process
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
    func hideBubble() { quoteGeneration += 1; bubble = false; updateAppearance() }
    func toggleQuota() {
        if bubble && message == nil { hideBubble() } else { showQuota() }
    }
    func resetPosition() {
        if followCodex { x = 1; y = 0 } else { desktopLeft = nil; desktopBottom = nil }
        hideBubble(); savePreferences()
    }
    func writePresence(visible: Bool) {
        try? writeJSON(["visible": visible, "backgroundQuota": alertPreferences.quotaEnabled, "at": Date().timeIntervalSince1970 * 1000,
                        "pid": ProcessInfo.processInfo.processIdentifier], to: dataDirectory.appendingPathComponent("presence.json"))
    }
    func savePreferences() {
        let file = dataDirectory.appendingPathComponent("preferences.json")
        var values = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let current: [String: Any] = ["layoutVersion": 2, "scale": scale, "volume": volume, "followCodex": followCodex, "loginRequested": loginRequested, "x": x, "y": y,
            "colorMode": colorMode.rawValue, "fullChance": fullChance, "textChance": textChance, "colorPaused": colorPaused,
            "specialQuotes": specialQuotes, "bubbleTapAdvance": bubbleTapAdvance, "language": language.rawValue,
            "desktopTopmost": desktopTopmost, "soundOn": soundOn, "hideMenu": hideMenu]
        if let data = try? JSONEncoder().encode(alertPreferences),
           let raw = try? JSONSerialization.jsonObject(with: data) { values["alerts"] = raw }
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
    func showAlert(_ text: String) {
        message = text; bubble = true
        updateAppearance(); restartTTL(delay: 0.52)
    }
    func playAlertSound() {
        if alertPreferences.soundEnabled, volume > 0,
           let sound = NSSound(contentsOf: resources.appendingPathComponent("release.wav"), byReference: false) {
            sounds.removeAll { !$0.isPlaying }; sounds.append(sound)
            sound.volume = Float(volume); sound.play()
        }
    }
    func showQuote() {
        let opening = !bubble
        loadQuotes()
        message = QuoteFile.choose(quotes, excluding: lastQuote) ?? "我在這裡，慢慢來就好。"
        lastQuote = message; bubble = true
        updateAppearance()
        restartTTL(delay: opening ? 0.52 : 0.28)
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
        guard soundOn, volume > 0, let sound = NSSound(contentsOf: resources.appendingPathComponent(name + ".wav"), byReference: false) else { return }
        sounds.removeAll { !$0.isPlaying }; sounds.append(sound)
        sound.volume = Float(volume); sound.play()
    }
    private func writeJSON(_ values: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
    }
}
