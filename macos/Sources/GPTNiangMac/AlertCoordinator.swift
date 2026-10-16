import AppKit
import GPTNiangCore

private struct CompletionEvent: Decodable { let threadId: String; let eventId: String; let at: Double }
private struct CompletionResponse: Decodable { let events: [CompletionEvent]; let sessionCount: Int?; let error: String? }

@MainActor
final class AlertCoordinator {
    private weak var model: WidgetModel?
    private let notifications: AlertNotifications
    private let playSound: () -> Void
    private var lastSoundAt = -Double.infinity
    private(set) var soundSignals = 0
    private var state = QuotaAlertState()
    private var queue = AlertBubbleQueue()
    private var quotaWasEnabled = false
    private var authorizationResolved = false
    private var authorizationPending = false
    private var authorized = false
    private var authorizationCallbacks: [() -> Void] = []
    private var lastPermissionCheck = -Double.infinity
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var pending = Data()
    private var generation = 0
    private var seen = Set<String>()
    private var nextRestart: TimeInterval = 0
    private(set) var completionSessions = 0
    private(set) var completionFrames = 0
    private(set) var completionEvents = 0
    var monitorRunning: Bool { process?.isRunning == true }
    var hostFrontmost = false
    var presentCompletionPopup: ((Int) -> Bool)?
    var dismissCompletionPopup: (() -> Void)?
    private(set) var popupPresentations = 0
    var windowVisible = false
    var windowBusy = false
    private var stateURL: URL { model!.dataDirectory.appendingPathComponent("alert-state.json") }

    init(model: WidgetModel, notifications: AlertNotifications? = nil, playSound: (() -> Void)? = nil) {
        self.model = model
        self.playSound = playSound ?? { [weak model] in model?.playAlertSound() }
        self.notifications = notifications ?? SystemAlertNotifications()
        if let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(QuotaAlertState.self, from: data) { state = saved }
    }
    func configure() {
        guard let model else { return }
        queue.clear()
        if !model.alertPreferences.completionEnabled || !model.alertPreferences.completionPopupEnabled || !model.followCodex {
            dismissCompletionPopup?()
        }
        model.alertPreferences.validate()
        let enabled = model.alertPreferences.quotaEnabled
        if enabled && !quotaWasEnabled { authorizationResolved = false; refreshAuthorization(request: true) }
        quotaWasEnabled = enabled
        if !model.alertPreferences.completionEnabled { stopMonitor(); model.alertMonitorError = nil }
        if !enabled && !model.alertPreferences.completionEnabled { queue.clear() }
        // Update a heartbeat immediately so hidden-window quota monitoring can
        // start/stop without creating another worker or a refresh race.
        model.writePresence(visible: windowVisible)
        tick()
    }
    private func refreshAuthorization(request: Bool, then: (() -> Void)? = nil) {
        if let then { authorizationCallbacks.append(then) }
        guard !authorizationPending else { return }
        authorizationPending = true
        lastPermissionCheck = ProcessInfo.processInfo.systemUptime
        notifications.authorize(request: request) { [weak self] allowed in self?.setAuthorization(allowed) }
    }

    private func setAuthorization(_ allowed: Bool) {
        authorized = allowed; authorizationResolved = true; authorizationPending = false
        model?.alertPermissionDenied = !allowed
        let callbacks = authorizationCallbacks; authorizationCallbacks = []
        callbacks.forEach { $0() }
    }
    func refreshPermission() {
        if model?.alertPreferences.quotaEnabled == true { refreshAuthorization(request: false) }
    }
    func tick() {
        guard let model else { return }
        let now = Date()
        if model.alertPreferences.quotaEnabled && ProcessInfo.processInfo.systemUptime - lastPermissionCheck >= 60 {
            refreshPermission()
        }
        if model.alertPreferences.quotaEnabled && authorizationResolved {
            var next = state
            let alerts = next.evaluate(model.snapshot, preferences: model.alertPreferences, now: now)
            if next != state {
                do {
                    try JSONEncoder().encode(next).write(to: stateURL, options: .atomic)
                    state = next
                    if !alerts.isEmpty {
                        let texts = alerts.map { alert in
                            let window = alert.window
                            let summary = alert.exhausted
                                ? model.text("%@额度已耗尽", window.title(language: model.language))
                                : model.text("%@额度剩余 %@%%", window.title(language: model.language), window.percentageText)
                            return summary + " · " + window.resetText(at: now, language: model.language)
                        }
                        let text = texts.joined(separator: "\n")
                        enqueue(text, now: now); notify(text)
                    }
                    model.alertStorageError = nil
                } catch { model.alertStorageError = model.text("提醒记录无法保存，请检查数据目录权限。") }
            }
        }
        if model.alertPreferences.completionEnabled && process?.isRunning != true && ProcessInfo.processInfo.systemUptime >= nextRestart { startMonitor() }
        if let text = queue.take(now: now, visible: windowVisible,
                                 busy: windowBusy || model.interactionActive || model.bubble) {
            model.showAlert(text)
        }
    }
    private func enqueue(_ text: String, now: Date) {
        queue.append(text, now: now)
        signalSound()
    }
    private func signalSound() {
        // Audio belongs to receipt, not bubble visibility. Coalesce simultaneous
        // quota/completion signals so a batch does not play overlapping sounds.
        guard let model, model.alertPreferences.soundEnabled, model.volume > 0 else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - lastSoundAt >= 1 else { return }
        lastSoundAt = uptime; soundSignals += 1; playSound()
    }
    private func notify(_ text: String) {
        guard authorized else { return }
        notifications.send(title: model?.text("GPT 娘 · 额度提醒") ?? "GPT 娘", body: text) { [weak self] sent in
            if !sent { self?.model?.alertStorageError = self?.model?.text("系统通知未能发送，桌宠提醒仍可使用。") }
        }
    }

    func test() {
        guard let model else { return }
        let text = model.text("这是一条测试提醒，额度没有发生变化。")
        enqueue(text, now: Date())
        refreshAuthorization(request: true) { [weak self] in self?.notify(text) }
        tick()
    }
    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    private func startMonitor() {
        guard let model, let node = model.findNode() else {
            model?.alertMonitorError = model?.text("找不到任务监测所需的 Node.js。")
            nextRestart = ProcessInfo.processInfo.systemUptime + 30; return
        }
        generation += 1
        let current = generation
        let task = Process(), input = Pipe(), output = Pipe()
        pending.removeAll(); seen.removeAll()
        task.executableURL = node
        task.arguments = [model.resources.appendingPathComponent("Backend/runtime/completion-watch.mjs").path]
        task.standardInput = input; task.standardOutput = output; task.standardError = FileHandle.nullDevice
        task.environment = ProcessInfo.processInfo.environment
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in if self?.generation == current { self?.consume(data) } }
        }
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.stopMonitor()
                self.nextRestart = ProcessInfo.processInfo.systemUptime + 30
                self.model?.alertMonitorError = self.model?.text("任务监测已中断，将自动重试。")
            }
        }
        do { try task.run(); self.process = task; self.input = input; self.output = output; model.alertMonitorError = nil }
        catch {
            output.fileHandleForReading.readabilityHandler = nil
            nextRestart = ProcessInfo.processInfo.systemUptime + 30
            model.alertMonitorError = model.text("任务监测已中断，将自动重试。")
        }
    }
    func consume(_ data: Data) {
        guard let model, model.alertPreferences.completionEnabled else { return }
        pending.append(data)
        guard pending.count <= 512 * 1024 else { pending.removeAll(); return }
        while let end = pending.firstIndex(of: 10) {
            let line = Data(pending[..<end]); pending.removeSubrange(...end)
            guard let response = try? JSONDecoder().decode(CompletionResponse.self, from: line) else { continue }
            completionSessions = response.sessionCount ?? 0
            completionFrames += 1; completionEvents += response.events.count
            model.alertMonitorError = response.error == nil ? nil : model.text("本机会话索引暂时无法读取，将自动重试。")
            let now = Date(), milliseconds = now.timeIntervalSince1970 * 1000
            let fresh = response.events.filter { event in
                guard event.eventId.count <= 500, event.at.isFinite,
                      milliseconds - event.at >= -5000, milliseconds - event.at <= 30000 else { return false }
                return seen.insert(event.eventId).inserted
            }
            if seen.count > 256 { seen = Set(fresh.map(\.eventId)) }
            if !fresh.isEmpty {
                let text = fresh.count == 1 ? model.text("Codex 本轮回复已结束") : model.text("Codex 有 %@ 轮回复已结束", String(fresh.count))
                signalSound()
                let usePopup = CompletionPresentation.shouldPopup(preferences: model.alertPreferences,
                    followCodex: model.followCodex, hostFrontmost: hostFrontmost, mainVisible: windowVisible)
                if usePopup, presentCompletionPopup?(fresh.count) == true {
                    popupPresentations += 1
                } else {
                    queue.append(text, now: now)
                }
            }
        }
    }
    private func stopMonitor() {
        generation += 1
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil; input = nil; output = nil; pending.removeAll(); seen.removeAll()
    }
    func stop() { stopMonitor(); queue.clear(); dismissCompletionPopup?() }
}
