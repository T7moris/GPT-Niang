import AppKit
import SwiftUI
import Combine
import GPTNiangCore
import Darwin
import os

@main
struct GPTNiangEntry {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var model: WidgetModel!
    private var updater: NativeUpdater!
    private var languageSubscription: AnyCancellable?
    private var trackingMenus = 0
    private var panel: NSPanel!
    private var settingsWindow: NSWindow?
    private var speedWindow: NSWindow?
    private let speedStore = ThreadSpeedStore()
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var lockDescriptor: Int32 = -1
    private var hostRect: CGRect?
    private var lastHostNumber: Int?
    private var selectedHostNumber: Int?
    private var hostApplication: NSRunningApplication?
    private var cadence = WindowFollowCadence()
    private var wasCodexFrontmost = false
    private var followPolicy = WindowFollowPolicy()
    private let stageManagerPreferences = UserDefaults(suiteName: "com.apple.WindowManager")
    private var dragOrigin: CGPoint?
    private var previousFollow: Bool?
    private var dragEvents = 0
    private var diagnosticsURL: URL?
    private let logger = Logger(subsystem: "io.github.t7moris.GPTNiangMac", category: "window")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        func argument(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        let dataDirectory = argument("--data-dir").map { URL(fileURLWithPath: $0, isDirectory: true) } ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GPTNiangUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        lockDescriptor = Darwin.open(dataDirectory.appendingPathComponent("gui.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            // Reopening the app must not create a second character or quota worker.
            NSApp.terminate(nil); return
        }
        if Bundle.main.bundleURL.pathExtension == "app" {
            do {
                if try NativeUpdater.recoverBeforeLaunch(data: dataDirectory) { NSApp.terminate(nil); return }
            } catch { logger.error("Update recovery: \(error.localizedDescription, privacy: .public)") }
        }
        guard let resources = Bundle.main.resourceURL else { NSApp.terminate(nil); return }
        diagnosticsURL = argument("--diagnostics").map { URL(fileURLWithPath: $0) }
        model = WidgetModel(dataDirectory: dataDirectory, resources: resources)
        updater = NativeUpdater(data: dataDirectory, idle: { [weak self] in
            guard let self else { return false }
            return self.dragOrigin == nil && self.trackingMenus == 0 && self.settingsWindow?.isVisible != true &&
                self.speedWindow?.isVisible != true && self.model.updateIdle
        }, terminate: { NSApp.terminate(nil) })
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 378, height: 378),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = model.text("GPT 娘額度掛件")
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.isFloatingPanel = false; panel.hidesOnDeactivate = false
        panel.collectionBehavior = panelBehavior(following: model.followCodex)
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: WidgetView(model: model, onDrag: { [weak self] in self?.drag($0) }, onSettings: { [weak self] in self?.showSettings() }, onContextMenu: { [weak self] event, view in self?.showContextMenu(event, view: view) }))
        buildMenu()
        languageSubscription = model.$language.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.buildMenu(); self?.localizeWindowTitles() }
        }
        model.start()
        updateWindow()
        let followTimer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateWindow() }
        }
        // Keep following while AppKit is tracking a pointer or menu.
        RunLoop.main.add(followTimer, forMode: .common)
        timer = followTimer
        if args.contains("--speed") { showSpeed() }
        updater.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if self?.model.workerRunning == true { NativeUpdater.confirmLaunch(data: dataDirectory) }
        }
        logger.info("macOS widget launched")
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); updater?.stop(); model?.stop(); speedStore.stop()
        if lockDescriptor >= 0 { Darwin.close(lockDescriptor) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func menuWillOpen(_ menu: NSMenu) {
        trackingMenus += 1
        for item in menu.items {
            if item.action == #selector(showQuota) { item.title = model.text(model.bubble && model.message == nil ? "收起气泡" : "查看額度") }
        }
    }
    func menuDidClose(_ menu: NSMenu) { trackingMenus = max(0, trackingMenus - 1) }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if window === speedWindow { speedStore.stop() }
            if window === settingsWindow || window === speedWindow { NSApp.setActivationPolicy(.accessory) }
        }
    }
    private func localizeWindowTitles() {
        panel?.title = model.text("GPT 娘額度掛件")
        settingsWindow?.title = model.text("GPT 娘設定")
        speedWindow?.title = model.text("GPT 娘 · 聊天速度")
    }
    private func buildMenu() {
        if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
        statusItem?.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: model.text("GPT 娘"))
        let menu = NSMenu(); menu.delegate = self
        for (title, selector) in [(model.text("GPT 娘 · Codex 額度"), #selector(showQuota)), (model.text("刷新額度"), #selector(refresh)), (model.text("來一句語錄"), #selector(quote)), (model.text("聊天速度…"), #selector(showSpeed))] {
            let item = NSMenuItem(title: model.text(title), action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: model.text("設定…"), action: #selector(showSettings), keyEquivalent: ","); settings.target = self; menu.addItem(settings)
        let update = NSMenuItem(title: model.text("檢查更新…"), action: #selector(checkUpdate), keyEquivalent: ""); update.target = self; menu.addItem(update)
        let quit = NSMenuItem(title: model.text("退出 GPT 娘"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); menu.addItem(quit)
        statusItem?.menu = menu
        let main = NSMenu()
        let appMenu = NSMenuItem()
        let applicationMenu = NSMenu(title: model.text("GPT 娘")); applicationMenu.delegate = self
        for item in menu.items {
            if item.isSeparatorItem { applicationMenu.addItem(.separator()); continue }
            let copy = NSMenuItem(title: item.title, action: item.action, keyEquivalent: item.keyEquivalent)
            copy.target = item.target; applicationMenu.addItem(copy)
        }
        appMenu.submenu = applicationMenu; main.addItem(appMenu)
        let editItem = NSMenuItem(title: model.text("編輯"), action: nil, keyEquivalent: "")
        let edit = NSMenu(title: model.text("編輯"))
        for (title, selector, key) in [(model.text("復原"), Selector(("undo:")), "z"), (model.text("剪下"), #selector(NSText.cut(_:)), "x"), (model.text("複製"), #selector(NSText.copy(_:)), "c"), (model.text("貼上"), #selector(NSText.paste(_:)), "v"), (model.text("全選"), #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: model.text(title), action: selector, keyEquivalent: key)
        }
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
    }
    private func showContextMenu(_ event: NSEvent, view: NSView) {
        guard let menu = statusItem?.menu?.copy() as? NSMenu else { return }
        menu.delegate = self
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
    @objc private func showQuota() { model.toggleQuota(); updateWindow() }
    @objc private func refresh() { model.refresh() }
    @objc private func quote() { model.showQuote() }
    @objc private func checkUpdate() { showSettings(); updater.check(manual: true) }
    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 620), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = model.text("GPT 娘設定"); window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(model: model, updater: updater))
            window.center(); settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func showSpeed() {
        if speedWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 580), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = model.text("GPT 娘 · 聊天速度"); window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: ThreadSpeedView(store: speedStore, model: model)); window.center(); speedWindow = window
        }
        speedStore.start(model: model)
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        speedWindow?.makeKeyAndOrderFront(nil)
    }
    private func codexWindow(now: TimeInterval, frontmost: Bool) -> (CGRect, Int)? {
        let discover = cadence.discover(now: now, force: frontmost && !wasCodexFrontmost)
        if discover {
            hostApplication = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first
        }
        guard let app = hostApplication, !app.isTerminated, !app.isHidden else { return nil }
        let options: CGWindowListOption = discover ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionIncludingWindow]
        let windowID: CGWindowID? = discover ? kCGNullWindowID : selectedHostNumber.map { CGWindowID($0) }
        guard let windowID,
              let windows = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowIsOnscreen as String] as? Bool) == true,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) >= 0.95,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"], width >= 480, height >= 300,
                  let number = window[kCGWindowNumber as String] as? Int else { continue }
            let quartz = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: width, height: height)
            let frame = WidgetPlacement.appKitRect(quartz: quartz, mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
            // A full list is front-to-back: choose the current foremost Codex
            // window rather than retaining an older, still-visible window.
            // Stage Manager can report the backing window while it is in a
            // thumbnail/offscreen transition. Never attach to a screen sliver.
            guard followTarget(frame: frame, number: number) != nil else { continue }
            selectedHostNumber = number
            return (frame, number)
        }
        selectedHostNumber = nil
        return nil
    }
    private func panelBehavior(following: Bool) -> NSWindow.CollectionBehavior {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        if following { behavior.formUnion([.canJoinAllApplications, .transient]) }
        return behavior
    }
    private func followTarget(frame: CGRect, number: Int) -> FollowWindowTarget? {
        let size = CGSize(width: 378 * model.scale, height: 378 * model.scale)
        let candidate = WidgetPlacement.frame(host: frame, visibleScreen: frame, size: size, x: model.x, y: model.y)
        let center = CGPoint(x: candidate.midX, y: candidate.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ??
            NSScreen.screens.max(by: { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area }) else { return nil }
        return WindowFollowPolicy.target(number: number, frame: frame, visibleScreen: screen.visibleFrame, requestedScale: model.scale)
    }
    private func updateWindow() {
        guard model != nil, panel != nil else { return }
        if let previousFollow, previousFollow != model.followCodex {
            if !model.followCodex && model.desktopLeft == nil {
                model.desktopLeft = panel.frame.minX; model.desktopBottom = panel.frame.minY
            }
            dragOrigin = nil; followPolicy = WindowFollowPolicy(); lastHostNumber = nil; model.savePreferences()
        }
        previousFollow = model.followCodex
        let behavior = panelBehavior(following: model.followCodex)
        if panel.collectionBehavior != behavior { panel.collectionBehavior = behavior }
        var size = CGSize(width: 378 * model.scale, height: 378 * model.scale)
        let now = ProcessInfo.processInfo.systemUptime
        let codexFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex"
        // WindowServer's "onscreen" bit alone does not identify the active
        // Stage Manager set. Do not leave an overlay on another app/the desktop.
        let stageManagerEnabled = stageManagerPreferences?.bool(forKey: "GloballyEnabled") == true
        let followAllowed = !stageManagerEnabled || codexFrontmost
        let host = model.followCodex && followAllowed ? codexWindow(now: now, frontmost: codexFrontmost) : nil
        var visible = false
        if model.followCodex {
            panel.level = .normal
            let target = host.flatMap { followTarget(frame: $0.0, number: $0.1) }
            if let target = followPolicy.update(target: target, now: now, allowed: followAllowed) {
                let area = target.area
                hostRect = area
                if abs(model.displayScale - target.scale) > 0.001 { model.displayScale = target.scale }
                size = CGSize(width: 378 * target.scale, height: 378 * target.scale)
                if dragOrigin == nil {
                    let frame = WidgetPlacement.frame(host: area, visibleScreen: area, size: size, x: model.x, y: model.y)
                    if panel.frame != frame { panel.setFrame(frame, display: true) }
                }
                if !panel.isVisible || lastHostNumber != target.number || (codexFrontmost && !wasCodexFrontmost) {
                    panel.order(.above, relativeTo: target.number)
                }
                visible = panel.isVisible; lastHostNumber = target.number
                if model.trackingNote != nil { model.trackingNote = nil }
            } else {
                // Hide immediately on a missing/invalid host or leaving the
                // current stage. Reappearing requires a stable valid target.
                if panel.isVisible { panel.orderOut(nil) }
                lastHostNumber = nil; hostRect = nil; dragOrigin = nil
                let note = model.text("未找到可見的 Codex 主視窗。你仍可關閉跟隨，在桌面顯示掛件。")
                if model.trackingNote != note { model.trackingNote = note }
            }
        } else {
            let level: NSWindow.Level = model.desktopTopmost ? .floating : .normal
            let levelChanged = panel.level != level
            panel.level = level
            let point = CGPoint(x: model.desktopLeft ?? panel.frame.minX, y: model.desktopBottom ?? panel.frame.minY)
            let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.screens.min {
                hypot($0.frame.midX-point.x, $0.frame.midY-point.y) < hypot($1.frame.midX-point.x, $1.frame.midY-point.y)
            } ?? NSScreen.main!
            let area = screen.visibleFrame
            let fitted = min(model.scale, area.width / 378, area.height / 378)
            if abs(model.displayScale - fitted) > 0.001 { model.displayScale = fitted }
            size = CGSize(width: 378 * fitted, height: 378 * fitted)
            if dragOrigin == nil {
                model.migrateDesktopPosition(area: area, size: size)
                let defaultFrame = WidgetPlacement.frame(host: area, visibleScreen: area, size: size, x: 1, y: 0)
                let frame = WidgetPlacement.desktopFrame(area: area, size: size,
                    origin: CGPoint(x: model.desktopLeft ?? defaultFrame.minX, y: model.desktopBottom ?? defaultFrame.minY))
                if panel.frame != frame { panel.setFrame(frame, display: true) }
            }
            if !panel.isVisible || levelChanged { panel.orderFrontRegardless() }; visible = true; hostRect = area
        }
        if let area = hostRect {
            let left = panel.frame.midX < area.midX
            if model.facingLeft != left { model.facingLeft = left }
        }
        wasCodexFrontmost = codexFrontmost
        if cadence.presence(now: now, visible: visible) { model.writePresence(visible: visible) }
        if let diagnosticsURL, cadence.diagnostics(now: now) {
            let values: [String: Any] = ["visible": panel.isVisible, "followCodex": model.followCodex, "hostFound": host != nil,
                "hostWindow": host?.1 ?? 0, "frame": NSStringFromRect(panel.frame), "quotaOK": model.snapshot.ok,
                "stageManagerEnabled": stageManagerEnabled, "codexFrontmost": codexFrontmost, "followAllowed": followAllowed,
                "panelOnActiveSpace": panel.isOnActiveSpace, "panelOcclusionVisible": panel.occlusionState.contains(.visible),
                "collectionBehavior": panel.collectionBehavior.rawValue,
                "hostArea": hostRect.map { NSStringFromRect($0) } ?? "",
                "queryOK": model.snapshot.queryOk ?? false, "quotaWindowCount": model.snapshot.windows.count,
                "hasMessage": model.message != nil, "bubbleVisible": model.bubble, "scale": model.scale,
                "settingsVisible": settingsWindow?.isVisible ?? false, "speedVisible": speedWindow?.isVisible ?? false, "speedRows": speedStore.rows.count, "dragEvents": dragEvents, "displayScale": model.displayScale, "at": Date().timeIntervalSince1970]
            if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: diagnosticsURL, options: .atomic) }
        }
    }
    private func drag(_ translation: CGSize) {
        if translation == .zero {
            if model.followCodex, let area = hostRect {
                let travel = max(0, area.width - panel.frame.width - 24)
                if model.x * travel <= 18 { model.x = 0 }
                if (1 - model.x) * travel <= 18 { model.x = 1 }
            }
            dragOrigin = nil; return
        }
        dragEvents += 1
        if dragOrigin == nil { dragOrigin = panel.frame.origin }
        guard let origin = dragOrigin else { return }
        let proposed = CGPoint(x: origin.x + translation.width, y: origin.y - translation.height)
        if !model.followCodex {
            let center = CGPoint(x: proposed.x+panel.frame.width/2, y: proposed.y+panel.frame.height/2)
            let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.screens.min {
                hypot($0.frame.midX-center.x, $0.frame.midY-center.y) < hypot($1.frame.midX-center.x, $1.frame.midY-center.y)
            }
            guard let area = screen?.visibleFrame else { return }
            let frame = WidgetPlacement.desktopFrame(area: area, size: panel.frame.size, origin: proposed)
            panel.setFrameOrigin(frame.origin); model.desktopLeft = frame.minX; model.desktopBottom = frame.minY
            let left = frame.midX < area.midX
            if model.facingLeft != left { model.facingLeft = left }; hostRect = area
            return
        }
        guard let area = hostRect else { return }
        let insetX = min(12, max(0, area.width - panel.frame.width))
        let insetY = min(12, max(0, area.height - panel.frame.height))
        let usableX = max(0, area.width - panel.frame.width - 24)
        let usableY = max(0, area.height - panel.frame.height - 24)
        if usableX > 0 { model.x = min(1, max(0, (proposed.x - area.minX - insetX) / usableX)) }
        if usableY > 0 { model.y = min(1, max(0, (proposed.y - area.minY - insetY) / usableY)) }
        // Do not resize or reorder the window while its drag gesture is active.
        panel.setFrameOrigin(CGPoint(x: area.minX + insetX + usableX * model.x, y: area.minY + insetY + usableY * model.y))
    }
}

private extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }
