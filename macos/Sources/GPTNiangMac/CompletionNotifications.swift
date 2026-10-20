import AppKit
import SwiftUI
import GPTNiangCore

private struct CompletionNotice: Decodable {
    let type: String
    let sessionId: String
    let turnId: String
    let endedAt: Double
}

// FileHandle callbacks run outside the main actor; keep the queue bounded and
// invalidate the token before stopping a child so old callbacks cannot replay.
private final class CompletionInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UUID?
    private var pending = Data()
    private var discarding = false
    private var notices: [CompletionNotice] = []
    func begin() -> UUID {
        lock.lock(); defer { lock.unlock() }
        let next = UUID(); token = next; pending.removeAll(); notices.removeAll(); discarding = false; return next
    }
    func invalidate() { lock.lock(); token = nil; pending.removeAll(); notices.removeAll(); lock.unlock() }
    func append(_ data: Data, token expected: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard token == expected else { return }
        for byte in data {
            if byte == 10 {
                if !discarding, let notice = try? JSONDecoder().decode(CompletionNotice.self, from: pending),
                   notice.type == "completion", !notice.sessionId.isEmpty, !notice.turnId.isEmpty, notice.endedAt.isFinite {
                    if notices.count == 64 { notices.removeFirst() }; notices.append(notice)
                }
                pending.removeAll(keepingCapacity: true); discarding = false
            } else if !discarding {
                if pending.count < 2048 { pending.append(byte) } else { pending.removeAll(keepingCapacity: true); discarding = true }
            }
        }
    }
    func drain() -> [CompletionNotice] {
        lock.lock(); defer { lock.unlock() }; let result = notices; notices.removeAll(keepingCapacity: true); return result
    }
}

@MainActor
final class CompletionNotificationController {
    private struct OriginalLayer {
        let level: NSWindow.Level
        let visible: Bool
        let ignoresMouse: Bool
        let fullscreen: Bool
        let foregroundPID: Int32?
    }
    private let model: WidgetModel
    private let mainPanel: NSPanel
    private var state = CompletionReminderState()
    private let inbox = CompletionInbox()
    private var monitor: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var nextStart: TimeInterval = 0
    private var lastPoll: TimeInterval = 0
    private var wasEnabled = false
    private var originalLayer: OriginalLayer?
    private var closingUntil: TimeInterval = 0
    private var lastFullscreenCheck: TimeInterval = 0
    var temporaryTopmost: Bool { originalLayer != nil }
    init(model: WidgetModel, panel: NSPanel) {
        self.model = model; mainPanel = panel
        model.onManualBubble = { [weak self] in
            guard let self, self.state.surface != nil else { return }; self.dismiss()
        }
    }
    func stop() { dismiss(); stopMonitor() }
    private func restoreLayer() {
        guard let old = originalLayer else { return }; originalLayer = nil
        mainPanel.level = old.level; mainPanel.ignoresMouseEvents = old.ignoresMouse
        if !old.visible { mainPanel.orderOut(nil) }
    }
    private func dismiss() {
        restoreLayer(); model.hideCompletion(); state.dismiss(now: Date().timeIntervalSince1970)
        closingUntil = Date().timeIntervalSince1970 + 0.55
    }
    private func startMonitor(now: TimeInterval) {
        guard monitor?.isRunning != true, now >= nextStart else { return }
        stopMonitor(); nextStart = now + 5
        guard let node = model.findNode() else { return }
        let script = model.resources.appendingPathComponent("Backend/runtime/completion-monitor.mjs")
        guard FileManager.default.fileExists(atPath: script.path) else { return }
        let process = Process(), stdin = Pipe(), stdout = Pipe(), token = inbox.begin(), queue = inbox
        process.executableURL = node; process.arguments = [script.path]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil; return }; queue.append(bytes, token: token)
        }
        do { try process.run(); monitor = process; input = stdin; output = stdout }
        catch { stdout.fileHandleForReading.readabilityHandler = nil; inbox.invalidate(); try? stdin.fileHandleForWriting.close() }
    }
    private func stopMonitor() {
        inbox.invalidate(); output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close(); try? output?.fileHandleForReading.close()
        if let process = monitor, process.isRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if process.isRunning { process.terminate() } }
        }
        monitor = nil; input = nil; output = nil
    }

    func tick(codexFrontmost: Bool, busy: Bool) {
        let now = Date().timeIntervalSince1970
        if model.completionEnabled != wasEnabled {
            wasEnabled = model.completionEnabled
            if !wasEnabled { stop(); nextStart = 0 }
        }
        guard model.completionEnabled else { return }
        if now - lastPoll >= 1 {
            lastPoll = now
            for notice in inbox.drain() { state.receive(endedAt: notice.endedAt / 1000) }
            startMonitor(now: now)
        }
        if let surface = state.surface {
            if now >= state.deadline { dismiss(); return }
            if busy {
                restoreLayer(); model.hideCompletion(); state.pause(); closingUntil = now + 0.55; return
            }
            if surface == .background {
                if codexFrontmost { dismiss(); return }
                if let old = originalLayer, old.fullscreen, now - lastFullscreenCheck >= 0.25 {
                    lastFullscreenCheck = now
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier != old.foregroundPID || !foregroundFullscreen() { dismiss() }
                }
            } else if !codexFrontmost || !mainPanel.isVisible {
                model.hideCompletion(); state.pause(); closingUntil = now + 0.55
            }
            return
        }
        guard state.pending, !busy, !model.bubble, now >= closingUntil else { return }
        if codexFrontmost {
            guard mainPanel.isVisible else { return }
            model.showCompletion(); state.show(.foreground, now: now, openingDelay: 0.52)
        } else {
            originalLayer = OriginalLayer(level: mainPanel.level, visible: mainPanel.isVisible,
                ignoresMouse: mainPanel.ignoresMouseEvents, fullscreen: foregroundFullscreen(),
                foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
            // Reuse the original panel at its existing frame; never save a temporary position.
            mainPanel.ignoresMouseEvents = true; mainPanel.level = .floating; mainPanel.orderFrontRegardless()
            model.showCompletion(); state.show(.background, now: now, openingDelay: 0.52)
        }
    }
    private func foregroundFullscreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let item = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let b = item[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
        let rect = WidgetPlacement.appKitRect(quartz: CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0), mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
        return NSScreen.screens.contains { rect.insetBy(dx: -1, dy: -1).contains($0.frame) }
    }
}
