import XCTest
@testable import GPTNiangCore

final class FollowPlacementTests: XCTestCase {
    func testFullHostTranslationPreservesSizeAndRelativePosition() throws {
        let host = CGRect(x: 100, y: 100, width: 900, height: 700)
        for scale in [0.6, 1.0, 2.5] {
            let size = CGSize(width: 378 * scale, height: 378 * scale)
            for x in [0.0, 0.25, 0.5, 1.0] {
                for y in [0.0, 0.5, 1.0] {
                    let original = try XCTUnwrap(WidgetPlacement.followFrame(host: host, size: size, x: x, y: y))
                    for delta in [CGPoint(x: -800, y: 0), CGPoint(x: 0, y: -750),
                                  CGPoint(x: 1600, y: 500), CGPoint(x: -2200, y: -1400)] {
                        let moved = try XCTUnwrap(WidgetPlacement.followFrame(host: host.offsetBy(dx: delta.x, dy: delta.y), size: size, x: x, y: y))
                        XCTAssertEqual(moved.minX, original.minX + delta.x, accuracy: 0.000000001)
                        XCTAssertEqual(moved.minY, original.minY + delta.y, accuracy: 0.000000001)
                        XCTAssertEqual(moved.size, size)
                    }
                }
            }
        }
    }

    func testSmallHostCropsInsteadOfReducingRequestedSize() throws {
        let host = CGRect(x: 0, y: 0, width: 480, height: 300)
        let size = CGSize(width: 945, height: 945)
        let frame = try XCTUnwrap(WidgetPlacement.followFrame(host: host, size: size, x: 1, y: 0))
        XCTAssertEqual(frame.size, size)
        XCTAssertEqual(WidgetPlacement.viewport(frame: frame, host: host), host)
    }

    func testViewportDoesNotRepositionOrScaleTheLogicalCanvas() throws {
        let full = CGRect(x: 100, y: 100, width: 378, height: 378)
        let cases = [
            (CGRect(x: 250, y: 0, width: 900, height: 700), CGRect(x: 250, y: 100, width: 228, height: 378)),
            (CGRect(x: 0, y: 250, width: 900, height: 700), CGRect(x: 100, y: 250, width: 378, height: 228)),
            (CGRect(x: 0, y: 0, width: 300, height: 300), CGRect(x: 100, y: 100, width: 200, height: 200))
        ]
        for (host, expected) in cases {
            let crop = try XCTUnwrap(WidgetPlacement.viewport(frame: full, host: host))
            XCTAssertEqual(crop, expected)
            XCTAssertTrue(host.contains(crop))
        }
    }

    func testNarrowVisibleStripIsAValidViewport() {
        let full = CGRect(x: 0, y: 0, width: 378, height: 378)
        XCTAssertEqual(WidgetPlacement.viewport(frame: full, host: CGRect(x: 0, y: 0, width: 378, height: 20)),
                       CGRect(x: 0, y: 0, width: 378, height: 20))
    }

    func testNoHostShowsFullCanvasForDesktopOrTemporaryReminder() {
        let full = CGRect(x: -300, y: -100, width: 378, height: 378)
        XCTAssertEqual(WidgetPlacement.viewport(frame: full, host: nil), full)
    }

    func testInvalidAndNonintersectingViewportsAreHidden() {
        let valid = CGRect(x: 0, y: 0, width: 900, height: 700)
        for rect in [CGRect.null, CGRect.infinite, .zero,
                     CGRect(x: CGFloat.nan, y: 0, width: 900, height: 700)] {
            XCTAssertNil(WidgetPlacement.viewport(frame: valid, host: rect))
            XCTAssertNil(WidgetPlacement.viewport(frame: rect, host: valid))
        }
        XCTAssertNil(WidgetPlacement.viewport(frame: valid, host: valid.offsetBy(dx: 2000, dy: 0)))
    }

    func testInvalidFollowGeometryIsRejected() {
        let valid = CGRect(x: 0, y: 0, width: 900, height: 700)
        let size = CGSize(width: 378, height: 378)
        for rect in [CGRect.null, CGRect.infinite, .zero,
                     CGRect(x: 0, y: CGFloat.infinity, width: 900, height: 700)] {
            XCTAssertNil(WidgetPlacement.followFrame(host: rect, size: size, x: 0.5, y: 0.5))
        }
        XCTAssertNil(WidgetPlacement.followFrame(host: valid, size: size, x: .nan, y: 0))
        XCTAssertNil(WidgetPlacement.followFrame(host: valid, size: size, x: 0, y: .infinity))
        XCTAssertNil(WidgetPlacement.followFrame(host: valid, size: .zero, x: 0, y: 0))
        XCTAssertNil(WidgetPlacement.followFrame(host: valid, size: CGSize(width: CGFloat.infinity, height: 378), x: 0, y: 0))
    }

    func testNormalHostRetainsExistingNormalizedPlacement() throws {
        let host = CGRect(x: 100, y: 100, width: 1200, height: 1000)
        let size = CGSize(width: 378, height: 378)
        for x in [0.0, 0.3, 1.0] {
            for y in [0.0, 0.7, 1.0] {
                XCTAssertEqual(try XCTUnwrap(WidgetPlacement.followFrame(host: host, size: size, x: x, y: y)),
                               WidgetPlacement.frame(host: host, visibleScreen: host, size: size, x: x, y: y))
            }
        }
    }
}
