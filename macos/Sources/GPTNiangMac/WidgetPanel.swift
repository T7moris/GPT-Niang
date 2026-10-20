import AppKit
import GPTNiangCore

/// A fixed logical canvas inside a cropped native window. WindowServer clips
/// the viewport at display edges; the character and its pointer view never move
/// within, or shrink to fit, the remaining visible part of the host.
@MainActor
final class WidgetPanel: NSPanel {
    private let viewport = NSView()
    private var canvas: NSView?
    private var savedPlacement: CGRect?
    var placementFrame: CGRect { savedPlacement ?? frame }

    func install(_ content: NSView) {
        canvas?.removeFromSuperview()
        viewport.autoresizesSubviews = false
        viewport.wantsLayer = true
        viewport.layer?.masksToBounds = true
        content.autoresizingMask = []
        canvas = content
        contentView = viewport
        content.frame = viewport.bounds
        viewport.addSubview(content)
    }

    /// Cropping never writes preferences or changes window order/level.
    @discardableResult
    func place(_ desired: CGRect, clippedTo host: CGRect?) -> Bool {
        guard let visible = WidgetPlacement.viewport(frame: desired, host: host),
              let canvas else { orderOut(nil); return false }
        savedPlacement = desired
        if frame != visible { setFrame(visible, display: false) }
        let contentFrame = CGRect(x: desired.minX - visible.minX,
                                  y: desired.minY - visible.minY,
                                  width: desired.width, height: desired.height)
        if canvas.frame != contentFrame { canvas.frame = contentFrame }
        return true
    }
}
