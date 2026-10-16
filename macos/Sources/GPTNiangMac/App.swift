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
    private let completionPopup = CompletionPopupController()
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var lockDescriptor: Int32 = -1
    private var hostRect: CGRect?
    private var lastHostNumber: Int?
    private var selectedHostNumber: Int?
    private var hostNeedsOrdering = false
    private var desktopNeedsOrdering = false
    private var hostApplication: NSRunningApplication?
    private var cadence = WindowFollowCadence()
    private var wasCodexFrontmost = false
    private var missingHostSince: TimeInterval?
    private var hostConfirmedMissing = false
    private var hostOrderCount = 0
    private var hostHideCount = 0
    private var lastHostOrderReason = "none"
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: WidgetView(model: model, onDrag: { [weak self] in self?.drag($0) }, onSettings: { [weak self] in self?.showSettings() }, onContextMenu: { [weak self] event, view in self?.showContextMenu(event, view: view) }))
        model.alerts.presentCompletionPopup = { [weak self] count in
            guard let self else { return false }
            return self.completionPopup.present(count: count, model: self.model)
        }
        model.alerts.dismissCompletionPopup = { [weak self] in self?.completionPopup.dismiss() }
        buildMenu()
        languageSubscription = model.$language.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.buildMenu(); self?.localizeWindowTitles() }
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(restoreWindowOrdering), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(restoreWindowOrdering),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
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
    @objc private func restoreWindowOrdering() {
        hostNeedsOrdering = true; desktopNeedsOrdering = true
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        restoreWindowOrdering(); updateWindow(); return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        timer?.invalidate(); updater?.stop(); model?.stop(); speedStore.stop()
        if lockDescriptor >= 0 { Darwin.close(lockDescriptor) }
    }
    func applicationDidBecomeActive(_ notification: Notification) { model?.alerts.refreshPermission() }
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
    private func codexWindow(now: TimeInterval, frontmost: Bool, forceDiscovery: Bool = false) -> (CGRect, Int)? {
        hostConfirmedMissing = false
        let discover = cadence.discover(now: now, force: forceDiscovery || (frontmost && !wasCodexFrontmost))
        if discover {
            hostApplication = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first
        }
        guard let app = hostApplication, !app.isTerminated, !app.isHidden else {
            hostConfirmedMissing = true; return nil
        }
        let options: CGWindowListOption = discover ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionIncludingWindow]
        let windowID: CGWindowID? = discover ? kCGNullWindowID : selectedHostNumber.map { CGWindowID($0) }
        guard let windowID else { hostConfirmedMissing = true; return nil }
        // A failed query is uncertain; an empty successful reply is not.
        guard let windows = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowIsOnscreen as String] as? Bool) == true,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"], width >= 480, height >= 300,
                  let number = window[kCGWindowNumber as String] as? Int else { continue }
            let quartz = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: width, height: height)
            let frame = WidgetPlacement.appKitRect(quartz: quartz, mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
            // A full list is front-to-back: choose the current foremost Codex
            // window rather than retaining an older, still-visible window.
            selectedHostNumber = number
            if discover {
                let orderedNumbers = windows.compactMap { $0[kCGWindowNumber as String] as? Int }
                hostNeedsOrdering = WindowFollowOrdering.needsOrdering(
                    frontToBack: orderedNumbers, host: number, panel: panel.windowNumber)
            }
            return (frame, number)
        }
        if !discover {
            // The cached window may have been minimized or closed. Look for
            // another eligible Codex window now, rather than hiding for a tick.
            return codexWindow(now: now, frontmost: frontmost, forceDiscovery: true)
        }
        selectedHostNumber = nil; hostConfirmedMissing = true
        return nil
    }
    private func updateWindow() {
        guard model != nil, panel != nil else { return }
        if let previousFollow, previousFollow != model.followCodex {
            if !model.followCodex && model.desktopLeft == nil {
                model.desktopLeft = panel.frame.minX; model.desktopBottom = panel.frame.minY
            }
            dragOrigin = nil; model.savePreferences()
        }
        previousFollow = model.followCodex
        var size = CGSize(width: 378 * model.scale, height: 378 * model.scale)
        let now = ProcessInfo.processInfo.systemUptime
        let codexFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex"
        let host = model.followCodex ? codexWindow(now: now, frontmost: codexFrontmost) : nil
        var visible = false
        if model.followCodex {
            // Clicking/selecting in the host can raise its normal-level window
            // above a peer panel before the next discovery. Keep the pet one
            // level above only while Codex is frontmost; other apps can still
            // cover both after focus moves away. This never activates the pet.
            let level: NSWindow.Level = codexFrontmost ? .floating : .normal
            let levelChanged = panel.level != level
            if levelChanged { panel.level = level }
            if let (rect, number) = host {
                missingHostSince = nil
                let candidate = WidgetPlacement.frame(host: rect, visibleScreen: rect, size: size, x: model.x, y: model.y)
                let center = CGPoint(x: candidate.midX, y: candidate.midY)
                let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.screens.max { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area } ?? NSScreen.main!
                let area = WidgetPlacement.usableArea(host: rect, visibleScreen: screen.visibleFrame)
                hostRect = area
                let fitted = min(model.scale, area.width / 378, area.height / 378)
                if abs(model.displayScale - fitted) > 0.001 { model.displayScale = fitted }
                size = CGSize(width: 378 * fitted, height: 378 * fitted)
                if dragOrigin == nil { let frame = WidgetPlacement.frame(host: rect, visibleScreen: screen.visibleFrame, size: size, x: model.x, y: model.y); if panel.frame != frame { panel.setFrame(frame, display: true) } }
                if !panel.isVisible || lastHostNumber != number || levelChanged || hostNeedsOrdering || (codexFrontmost && !wasCodexFrontmost) {
                    lastHostOrderReason = !panel.isVisible ? "show" : lastHostNumber != number ? "hostChanged" : levelChanged ? "levelChanged" : "repair"
                    panel.order(.above, relativeTo: number)
                    hostOrderCount += 1; hostNeedsOrdering = false
                }
                visible = true; lastHostNumber = number; if model.trackingNote != nil { model.trackingNote = nil }
            } else {
                if missingHostSince == nil { missingHostSince = now }
                let appHidden = hostApplication?.isHidden ?? true
                if WindowFollowVisibility.keepDuringMissingHost(appHidden: appHidden, confirmedMissing: hostConfirmedMissing, missingFor: now - missingHostSince!) {
                    visible = panel.isVisible
                } else {
                    if panel.isVisible { panel.orderOut(nil); hostHideCount += 1 }; lastHostNumber = nil; hostRect = nil
                    let note = model.text("未找到可見的 Codex 主視窗。你仍可關閉跟隨，在桌面顯示掛件。")
                    if model.trackingNote != note { model.trackingNote = note }
                }
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
            if !panel.isVisible || levelChanged || desktopNeedsOrdering {
                panel.orderFrontRegardless(); desktopNeedsOrdering = false
            }
            visible = true; hostRect = area
        }
        if let area = hostRect {
            let left = panel.frame.midX < area.midX
            if model.facingLeft != left { model.facingLeft = left }
        }
        model.alerts.hostFrontmost = codexFrontmost
        if completionPopup.isVisible && (!model.followCodex || !model.alertPreferences.completionEnabled ||
            !model.alertPreferences.completionPopupEnabled || (codexFrontmost && panel.isVisible)) {
            completionPopup.dismiss()
        }
        model.alerts.windowVisible = panel.isVisible
        model.alerts.windowBusy = dragOrigin != nil || trackingMenus > 0
        wasCodexFrontmost = codexFrontmost
        if cadence.presence(now: now, visible: visible) { model.writePresence(visible: visible) }
        if let diagnosticsURL, cadence.diagnostics(now: now) {
            let values: [String: Any] = ["visible": panel.isVisible, "followCodex": model.followCodex, "hostFound": host != nil,
                "hostOrderCount": hostOrderCount, "hostHideCount": hostHideCount, "lastHostOrderReason": lastHostOrderReason, "windowLevel": panel.level.rawValue,
                "hostConfirmedMissing": hostConfirmedMissing, "hostWindow": host?.1 ?? 0, "frame": NSStringFromRect(panel.frame), "quotaOK": model.snapshot.ok,
                "queryOK": model.snapshot.queryOk ?? false, "quotaWindowCount": model.snapshot.windows.count,
                "hasMessage": model.message != nil, "bubbleVisible": model.bubble, "scale": model.scale,
                "alertShortEnabled": model.alertPreferences.shortEnabled, "alertWeekEnabled": model.alertPreferences.weekEnabled,
                "alertCompletionEnabled": model.alertPreferences.completionEnabled,
                "alertCompletionPopupEnabled": model.alertPreferences.completionPopupEnabled,
                "alertPopupVisible": completionPopup.isVisible, "alertPopupCount": completionPopup.count,
                "alertPopupPresentations": model.alerts.popupPresentations, "alertMonitorRunning": model.alerts.monitorRunning,
                "alertSoundSignals": model.alerts.soundSignals, "alertPermissionDenied": model.alertPermissionDenied, "alertMonitorError": model.alertMonitorError != nil,
                "alertCompletionSessions": model.alerts.completionSessions, "alertCompletionFrames": model.alerts.completionFrames, "alertCompletionEvents": model.alerts.completionEvents,
                "alertWindowBusy": model.alerts.windowBusy, "alertInteractionBusy": model.interactionActive,
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
