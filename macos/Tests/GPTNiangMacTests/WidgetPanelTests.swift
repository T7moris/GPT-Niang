import AppKit
import SwiftUI
import XCTest
@testable import GPTNiangMac

@MainActor
final class WidgetPanelTests: XCTestCase {
    private func panel() -> (WidgetPanel, NSView) {
        _ = NSApplication.shared
        let panel = WidgetPanel(contentRect: CGRect(x: 100, y: 100, width: 378, height: 378),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 378, height: 378))
        panel.install(content)
        return (panel, content)
    }

    func testCroppedWindowKeepsFullCanvasAndScreenCoordinates() {
        let (panel, content) = self.panel(); defer { panel.close() }
        let desired = CGRect(x: 100, y: 100, width: 378, height: 378)
        let host = CGRect(x: 250, y: 200, width: 900, height: 700)
        XCTAssertTrue(panel.place(desired, clippedTo: host))
        XCTAssertEqual(panel.placementFrame, desired)
        XCTAssertEqual(panel.frame, desired.intersection(host))
        XCTAssertEqual(content.frame, CGRect(x: -150, y: -100, width: 378, height: 378))
        XCTAssertEqual(panel.convertPoint(toScreen: content.convert(.zero, to: nil)), desired.origin)
        XCTAssertTrue(panel.contentView?.layer?.masksToBounds == true)
    }

    func testHostTranslationPreservesGrabPointAndContentSize() {
        let (panel, content) = self.panel(); defer { panel.close() }
        let original = CGRect(x: 100, y: 100, width: 378, height: 378)
        for offset in [CGPoint(x: -700, y: -650), CGPoint(x: 1000, y: 400), .zero] {
            let desired = original.offsetBy(dx: offset.x, dy: offset.y)
            let host = CGRect(x: 250 + offset.x, y: 200 + offset.y, width: 900, height: 700)
            XCTAssertTrue(panel.place(desired, clippedTo: host))
            XCTAssertEqual(panel.placementFrame, desired)
            XCTAssertEqual(content.frame.size, original.size)
            XCTAssertEqual(panel.convertPoint(toScreen: content.convert(CGPoint(x: 180, y: 170), to: nil)),
                           CGPoint(x: desired.minX + 180, y: desired.minY + 170))
        }
    }

    func testTemporaryReminderRemovesCropAndCanRestoreIt() {
        let (panel, content) = self.panel(); defer { panel.close() }
        let desired = CGRect(x: 100, y: 100, width: 378, height: 378)
        let host = CGRect(x: 250, y: 200, width: 900, height: 700)
        XCTAssertTrue(panel.place(desired, clippedTo: host))
        let level = panel.level
        XCTAssertTrue(panel.place(panel.placementFrame, clippedTo: nil))
        XCTAssertEqual(panel.frame, desired); XCTAssertEqual(content.frame.origin, .zero)
        XCTAssertEqual(panel.level, level)
        XCTAssertTrue(panel.place(panel.placementFrame, clippedTo: host))
        XCTAssertEqual(panel.placementFrame, desired)
        XCTAssertEqual(panel.frame, desired.intersection(host))
    }

    func testInvalidViewportHidesWithoutReplacingLastValidPlacement() {
        let (panel, _) = self.panel(); defer { panel.close() }
        let desired = CGRect(x: 100, y: 100, width: 378, height: 378)
        XCTAssertTrue(panel.place(desired, clippedTo: nil))
        panel.orderFront(nil)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.place(.null, clippedTo: nil))
        XCTAssertEqual(panel.placementFrame, desired)
        XCTAssertFalse(panel.place(desired, clippedTo: desired.offsetBy(dx: 2000, dy: 0)))
        XCTAssertFalse(panel.isVisible)
    }

    func testHostingViewReceivesFullSizeEvenWhenViewportIsSmall() {
        let (panel, _) = self.panel(); defer { panel.close() }
        let content = NSHostingView(rootView: Color.clear.frame(width: 378, height: 378))
        panel.install(content)
        XCTAssertTrue(panel.place(CGRect(x: 100, y: 100, width: 378, height: 378),
                                 clippedTo: CGRect(x: 100, y: 100, width: 200, height: 100)))
        panel.layoutIfNeeded()
        XCTAssertEqual(content.frame.size, CGSize(width: 378, height: 378))
        XCTAssertEqual(panel.frame.size, CGSize(width: 200, height: 100))
        XCTAssertFalse(panel.styleMask.contains(.titled))
    }

    func testPointerDragKeepsItsFullCanvasOriginWhileViewportChanges() {
        let (panel, _) = self.panel(); defer { panel.close() }
        let view = CharacterInteraction.PointerView(frame: CGRect(x: 0, y: 0, width: 378, height: 378))
        panel.install(view)
        let desired = CGRect(x: 100, y: 100, width: 378, height: 378)
        let host = CGRect(x: 250, y: 200, width: 900, height: 700)
        XCTAssertTrue(panel.place(desired, clippedTo: host))
        var completed = false
        view.onClick = { XCTFail("drag became a click") }
        view.onDrag = { [weak panel] delta in
            if delta == .zero { completed = true }
            else { panel?.place(desired.offsetBy(dx: delta.width, dy: -delta.height), clippedTo: host) }
        }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                              windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 100, y: 100)))
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 110, y: 115)))
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 110, y: 115)))
        XCTAssertTrue(completed)
        XCTAssertEqual(panel.placementFrame, desired.offsetBy(dx: 10, dy: 15))
        XCTAssertEqual(view.frame.size, desired.size)
        XCTAssertTrue(host.contains(panel.frame))
    }
}
