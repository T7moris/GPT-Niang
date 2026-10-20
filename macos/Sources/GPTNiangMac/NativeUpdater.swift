import AppKit
import Combine
import GPTNiangUpdate
import GPTNiangCore
import Darwin

private struct MacUpdatePreferences: Codable { var automatic = true }
private struct MacUpdateSchedule: Codable { var nextCheck: TimeInterval = 0 }

@MainActor
final class NativeUpdater: ObservableObject {
    @Published var automatic = true {
        didSet {
            try? UpdateFiles.write(MacUpdatePreferences(automatic: automatic), to: data.appendingPathComponent("mac-update-preferences.json"))
            if automatic && !oldValue { check(manual: true) }
        }
    }
    @Published private(set) var status = "自動檢查正式版，每 24 小時一次"
    private var statusKey = "自動檢查正式版，每 24 小時一次"
    private var statusArguments: [String] = []
    func localizedStatus(_ language: InterfaceLanguage) -> String { language.text(statusKey, arguments: statusArguments) }
    private func setStatus(_ key: String, _ arguments: String...) {
        statusKey = key; statusArguments = arguments
        status = InterfaceLanguage.traditional.text(key, arguments: arguments)
    }
    @Published private(set) var busy = false
    let currentVersion: String
    private let data: URL
    private let app: URL
    private let idle: () -> Bool
    private let workerReady: (String) -> Bool
    private var launchConfirmed = false
    private let terminate: () -> Void
    private var ticker: Timer?
    private var operation: Task<Void, Never>?
    private var started = Date()
    private var cleanupChecked = false
    private var schedule: MacUpdateSchedule

    init(data: URL, app: URL = Bundle.main.bundleURL, version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         idle: @escaping () -> Bool, workerReady: @escaping (String) -> Bool, terminate: @escaping () -> Void) {
        self.data = UpdateFiles.canonical(data); self.app = UpdateFiles.canonical(app); self.idle = idle; self.terminate = terminate
        currentVersion = version ?? "dev"
        self.workerReady = workerReady
        schedule = (try? UpdateFiles.read(MacUpdateSchedule.self, at: data.appendingPathComponent("mac-update-schedule.json"))) ?? MacUpdateSchedule()
        automatic = ((try? UpdateFiles.read(MacUpdatePreferences.self, at: data.appendingPathComponent("mac-update-preferences.json"))) ?? MacUpdatePreferences()).automatic
        if let journal = try? UpdateFiles.read(UpdateJournal.self, at: data.appendingPathComponent("mac-update-transaction.json")) {
            if journal.phase == .committed { setStatus("已更新至 %@。", String(describing: journal.version)) }
            if journal.phase == .rolledBack { setStatus("更新未完成，已恢復 %@。", String(describing: journal.oldVersion)) }
            if journal.phase == .recoveryFailed { setStatus("更新恢復未完成，請查看資料目錄中的診斷記錄。") }
        }
    }
    func start() {
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.launchConfirmed {
                    self.launchConfirmed = Self.confirmLaunch(data: self.data, app: self.app, version: self.currentVersion,
                        workerReady: { self.workerReady(self.currentVersion) })
                }
                guard Date().timeIntervalSince(self.started) >= 30 else { return }
                if !self.cleanupChecked && !self.busy { self.cleanupChecked = true; self.clean(); return }
                if self.automatic && Date().timeIntervalSince1970 >= self.schedule.nextCheck { self.check(manual: false) }
            }
        }
    }
    func stop() { ticker?.invalidate(); ticker = nil; operation?.cancel() }
    private func sourceCheckout() -> Bool {
        var directory = app
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { return true }
            directory.deleteLastPathComponent()
        }
        return StableVersion(currentVersion) == nil
    }
    private func clean() {
        guard !busy, !sourceCheckout() else { return }
        busy = true
        operation = Task {
            defer { busy = false }
            do {
                let store = try UpdateStore(app: app, data: data); let lock = try UpdateLock(at: data)
                defer { withExtendedLifetime(lock) {} }
                try store.cleanup()
            } catch { setStatus("更新清理未完成：%@", error.localizedDescription) }
        }
    }
    func check(manual: Bool) {
        guard !busy else { return }
        guard !sourceCheckout() else { setStatus("源碼版本請使用 Git 更新。"); return }
        guard !app.path.contains("/AppTranslocation/"), FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            setStatus("請先將 GPT 娘移到可寫入的應用程式目錄。"); return
        }
        if !manual && (!automatic || Date().timeIntervalSince1970 < schedule.nextCheck) { return }
        schedule.nextCheck = Date().timeIntervalSince1970 + UpdatePolicy.day
        try? UpdateFiles.write(schedule, to: data.appendingPathComponent("mac-update-schedule.json"))
        busy = true
        operation = Task {
            defer { busy = false }
            var store: UpdateStore?; var token: String?; var keep = false; var lock: UpdateLock?
            defer {
                if let store, let token, !keep {
                    do { try store.removeOwned(store.artifact(token), token: token); try store.removeOwned(store.cache(token), token: token) }
                    catch { store.diagnose(error) }
                }
                withExtendedLifetime(lock) {}
            }
            do {
                let active = try UpdateStore(app: app, data: data); store = active
                lock = try UpdateLock(at: data)
                try active.cleanup()
                setStatus("正在檢查正式版…")
                let metadata = try await NativeDownload.bytes(from: UpdatePolicy.api, limit: 1024 * 1024)
                let release = try JSONDecoder().decode(OfficialRelease.self, from: metadata)
                guard let selected = try UpdatePolicy.select(release, current: currentVersion) else { setStatus("已是最新正式版。"); return }
                let id = UUID().uuidString; token = id
                try active.createOwned(active.cache(id), token: id)
                setStatus("正在下載 %@…", String(describing: selected.version))
                let sums = try await NativeDownload.bytes(from: selected.checksums.browser_download_url, limit: 1024 * 1024)
                try UpdatePolicy.verify(sums, asset: selected.checksums)
                let archive = try await NativeDownload.bytes(from: selected.archive.browser_download_url, limit: UpdatePolicy.maximumArchive)
                let prepared = try await Task.detached {
                    let digest = try UpdatePolicy.verifyArchive(archive, checksums: sums, asset: selected.archive)
                    let file = active.cache(id).appendingPathComponent("release.zip"); try archive.write(to: file, options: .atomic)
                    let candidate = try NativeArchive.extract(file, to: active.cache(id).appendingPathComponent("package", isDirectory: true))
                    try NativeArchive.validate(candidate, version: selected.version)
                    return (candidate, digest)
                }.value
                try Task.checkCancellation()
                setStatus("下載已驗證，請關閉設定視窗，等待掛件空閒後安裝。")
                try active.createOwned(active.artifact(id), token: id)
                try await Task.detached {
                    try FileManager.default.copyItem(at: prepared.0, to: active.staged(id))
                    try NativeArchive.validate(active.staged(id), version: selected.version)
                }.value
                try Task.checkCancellation()
                // Staging is asynchronous; wait for idle immediately before the helper handoff.
                while !idle() {
                    if !manual && !automatic { setStatus("自動更新已關閉，下載已清理。"); return }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                if !manual && !automatic { setStatus("自動更新已關閉，下載已清理。"); return }
                let journal = UpdateJournal(token: id, app: app, data: data, version: selected.version, oldVersion: currentVersion, hash: prepared.1,
                                            parentPID: ProcessInfo.processInfo.processIdentifier)
                try active.save(journal); keep = true
                lock = nil // The separate helper takes over the transaction lock.
                try Self.launchHelper(store: active, recover: false)
                setStatus("正在安裝更新，完成後會自動重新開啟。"); terminate()
            } catch {
                setStatus("更新失敗：%@", error.localizedDescription)
                if let delay = (error as? UpdateFailure)?.retryAfter { schedule.nextCheck = max(schedule.nextCheck, Date().timeIntervalSince1970 + delay) }
                try? UpdateFiles.write(schedule, to: data.appendingPathComponent("mac-update-schedule.json")); store?.diagnose(error)
            }
        }
    }
    private static func launchHelper(store: UpdateStore, recover: Bool) throws {
        let source = store.app.appendingPathComponent("Contents/Helpers/GPTNiangUpdater")
        let helper = store.data.appendingPathComponent("GPTNiangUpdater")
        try UpdateFiles.checkPath(helper)
        try Data(contentsOf: source).write(to: helper, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let process = Process(); process.executableURL = helper; process.arguments = [recover ? "--recover" : "--install", store.journalURL.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    }
    static func recoverBeforeLaunch(data: URL) throws -> Bool {
        let store = try UpdateStore(app: Bundle.main.bundleURL, data: data)
        guard let journal = try store.journal(), !journal.phase.terminal, journal.phase != .recoveryFailed else { return false }
        if let pid = journal.helperPID, kill(pid, 0) == 0 { return false }
        try launchHelper(store: store, recover: true); return true
    }
    @discardableResult
    static func confirmLaunch(data: URL, app: URL = Bundle.main.bundleURL,
                              version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                              workerReady: () -> Bool,
                              writeHealth: (UpdateHealth, URL) throws -> Void = { try UpdateFiles.write($0, to: $1) }) -> Bool {
        do {
            guard let journal = try UpdateFiles.read(UpdateJournal.self, at: data.appendingPathComponent("mac-update-transaction.json")) else { return true }
            let store = try UpdateStore(app: app, data: data)
            try store.validate(journal)
            if journal.phase.terminal { return true }
            guard journal.phase == .replaced, let version, version == journal.version, workerReady() else { return false }
            let ready = UpdateHealth(token: journal.token, version: version, appPath: store.app.path, pid: ProcessInfo.processInfo.processIdentifier)
            try writeHealth(ready, store.data.appendingPathComponent("mac-update-health.json"))
            return true
        } catch { return false } // Retry on the existing one-second updater tick.
    }
}
