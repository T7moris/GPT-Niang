import AppKit
import SwiftUI
import GPTNiangCore

private final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CompletionPopupController {
    private(set) var panel: NSPanel?
    private var lifetime = CompletionPopupLifetime()
    private var generation = 0
    private var categories: [TaskAlertKind: Int] = [:]
    var isVisible: Bool { panel?.isVisible == true }
    var count: Int { lifetime.count }

    @discardableResult func present(count: Int, model: WidgetModel) -> Bool {
        present(counts: [.completion: count], model: model)
    }
    @discardableResult func present(counts: [TaskAlertKind: Int], model: WidgetModel) -> Bool {
        let count = counts.values.reduce(0, +)
        guard count > 0 else { return false }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return false }
        let area = screen.visibleFrame
        guard let frame = WidgetPlacement.completionFrame(area: area, scale: model.scale) else { return false }
        if !lifetime.visible(now: ProcessInfo.processInfo.systemUptime) { categories.removeAll() }
        for (kind, value) in counts { categories[kind] = min(999, (categories[kind] ?? 0) + value) }
        lifetime.record(count: count, now: ProcessInfo.processInfo.systemUptime)
        let text = model.taskAlertText(categories)
        let scale = frame.width / 378
        if panel == nil {
            let window = CompletionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
            window.hidesOnDeactivate = false; window.isFloatingPanel = true
            window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel = window
        }
        guard let panel else { return false }
        panel.title = model.text("GPT 娘 · 任务提醒")
        panel.contentView = NSHostingView(rootView: CompletionPopupView(image: model.characterImage, text: text, scale: scale))
        panel.setFrame(frame, display: true)
        // A nonactivating, mouse-transparent panel: never activate the app or
        // make this window key. Main widget geometry/preferences stay untouched.
        panel.orderFrontRegardless()
        generation += 1
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.generation == current else { return }
            self.dismiss()
        }
        return true
    }
    func dismiss() {
        generation += 1; lifetime.dismiss(); categories.removeAll()
        panel?.orderOut(nil)
    }
}

struct CompletionPopupView: View {
    let image: NSImage?
    let text: String
    let scale: Double
    private let accent = Color(red: 0.455, green: 0.353, blue: 0.596)
    private let surface = Color(red: 0.965, green: 0.95, blue: 0.98)
    var body: some View {
        ZStack(alignment: .topLeading) {
            OriginalBubbleShape().fill(surface)
                .overlay(OriginalBubbleShape().stroke(accent, lineWidth: 4))
                .frame(width: 350, height: 239)
            Ellipse().fill(surface).overlay(Ellipse().stroke(accent, lineWidth: 4))
                .frame(width: 25, height: 18).offset(x: 108, y: 182)
            Ellipse().fill(surface).overlay(Ellipse().stroke(accent, lineWidth: 4))
                .frame(width: 17, height: 12).offset(x: 142, y: 214)
            Text(text).font(.system(size: 23, weight: .semibold, design: .rounded))
                .foregroundStyle(accent).multilineTextAlignment(.center)
                .lineLimit(5).minimumScaleFactor(0.6)
                .frame(width: 218, height: 126).offset(x: 46, y: 22)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(width: 208, height: 208).offset(x: 142, y: 142)
            }
        }
        .frame(width: 350, height: 350, alignment: .topLeading).padding(14)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: 378 * scale, height: 378 * scale, alignment: .topLeading)
        .environment(\.colorScheme, .light)
        .allowsHitTesting(false)
        .accessibilityLabel(text)
    }
}
