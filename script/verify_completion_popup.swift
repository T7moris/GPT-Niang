import AppKit
import SwiftUI
import GPTNiangCore

@main struct VerifyCompletionPopup {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("niang-popup-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: data) }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resources = root.appendingPathComponent("gpt-niang-usage/assets")
        let model = WidgetModel(dataDirectory: data, resources: resources)
        model.language = .simplified; model.followCodex = true; model.scale = 1
        model.desktopLeft = -333; model.desktopBottom = 123; model.x = 0.25; model.y = 0.75
        let prefs = [model.desktopLeft, model.desktopBottom, model.x, model.y]
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let controller = CompletionPopupController()
        precondition(controller.present(count: 1, model: model), "A GUI session and visible screen are required")
        let panel = controller.panel!
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, "popup must not activate the app")
        precondition(panel.isVisible && panel.level == .floating && !panel.canBecomeKey && !panel.canBecomeMain)
        precondition(!panel.isKeyWindow && !panel.isMainWindow && panel.ignoresMouseEvents)
        precondition(panel.styleMask.contains(.nonactivatingPanel) && !panel.hidesOnDeactivate)
        precondition(NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) })
        precondition([model.desktopLeft, model.desktopBottom, model.x, model.y] == prefs && model.followCodex)
        let samePanel = panel.windowNumber
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        precondition(controller.present(count: 2, model: model))
        precondition(controller.count == 3 && controller.panel?.windowNumber == samePanel)
        // Render only our own view to a file for visual QA; no screen capture.
        if let view = panel.contentView {
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]),
                   let target = ProcessInfo.processInfo.environment["GPT_NIANG_POPUP_PREVIEW"] {
                    try png.write(to: URL(fileURLWithPath: target))
                }
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(5.2))
        precondition(controller.isVisible, "new events must extend the deadline")
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        precondition(!controller.isVisible && controller.count == 0, "popup auto-dismisses six seconds after latest event")
        precondition([model.desktopLeft, model.desktopBottom, model.x, model.y] == prefs && model.followCodex)
        print("Native popup checks passed: nonactivating, mouse-transparent, screen-contained, merged, timed dismissal, unchanged preferences")
    }
}
