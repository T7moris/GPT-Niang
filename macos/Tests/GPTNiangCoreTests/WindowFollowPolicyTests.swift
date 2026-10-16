import XCTest
@testable import GPTNiangCore

final class WindowFollowPolicyTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func target(number: Int = 1, x: CGFloat = 100, y: CGFloat = 100,
                        width: CGFloat = 1000, height: CGFloat = 700) -> FollowWindowTarget {
        WindowFollowPolicy.target(number: number,
            frame: CGRect(x: x, y: y, width: width, height: height),
            visibleScreen: screen, requestedScale: 1)!
    }

    func testOffscreenNarrowStripAndFullyOffscreenHaveNoDesktopFallback() {
        let narrow = CGRect(x: 1420, y: 100, width: 1000, height: 700)
        XCTAssertNil(WindowFollowPolicy.target(number: 1, frame: narrow,
            visibleScreen: screen, requestedScale: 1))
        let outside = CGRect(x: 1600, y: 100, width: 1000, height: 700)
        XCTAssertNil(WindowFollowPolicy.target(number: 1, frame: outside,
            visibleScreen: screen, requestedScale: 1))
    }

    func testThumbnailAndInvalidGeometryAreRejected() {
        for frame in [CGRect(x: 0, y: 0, width: 16, height: 16),
                      CGRect(x: 0, y: 0, width: 479, height: 700),
                      CGRect(x: 0, y: 0, width: 1000, height: 299),
                      CGRect(x: CGFloat.nan, y: 0, width: 1000, height: 700),
                      CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 700)] {
            XCTAssertNil(WindowFollowPolicy.target(number: 1, frame: frame,
                visibleScreen: screen, requestedScale: 1))
        }
        for scale in [Double.nan, Double.infinity, 0.59, -1] {
            XCTAssertNil(WindowFollowPolicy.target(number: 1, frame: target().frame,
                visibleScreen: screen, requestedScale: scale))
        }
        XCTAssertNil(WindowFollowPolicy.target(number: 1, frame: target().frame,
            visibleScreen: .infinite, requestedScale: 1))
    }

    func testScaleFitsTheVisibleIntersectionAndHasAMinimum() {
        let partial = WindowFollowPolicy.target(number: 1,
            frame: CGRect(x: 1140, y: 100, width: 1000, height: 700),
            visibleScreen: screen, requestedScale: 2)!
        XCTAssertEqual(partial.area, CGRect(x: 1140, y: 100, width: 300, height: 700))
        XCTAssertEqual(partial.scale, 300.0 / 378, accuracy: 0.000001)
        let short = WindowFollowPolicy.target(number: 1,
            frame: CGRect(x: 100, y: 650, width: 1000, height: 700),
            visibleScreen: screen, requestedScale: 2)!
        XCTAssertEqual(short.scale, 250.0 / 378, accuracy: 0.000001)
        XCTAssertEqual(WindowFollowPolicy.target(number: 1, frame: target().frame,
            visibleScreen: screen, requestedScale: 0.7)?.scale, 0.7)
    }

    func testStableRecoveryWaitsFor150Milliseconds() {
        var policy = WindowFollowPolicy()
        let valid = target()
        XCTAssertNil(policy.update(target: valid, now: 0, allowed: true))
        XCTAssertNil(policy.update(target: valid, now: 0.149, allowed: true))
        XCTAssertEqual(policy.update(target: valid, now: 0.151, allowed: true), valid)
        XCTAssertNil(policy.update(target: nil, now: 0.2, allowed: true))
        XCTAssertNil(policy.update(target: valid, now: 0.3, allowed: true))
        XCTAssertEqual(policy.update(target: valid, now: 0.451, allowed: true), valid)
    }

    func testUnstableEntrySizeRestartsSettling() {
        var policy = WindowFollowPolicy()
        let large = target()
        let smaller = target(width: 600, height: 400)
        XCTAssertNil(policy.update(target: large, now: 0, allowed: true))
        XCTAssertNil(policy.update(target: smaller, now: 0.1, allowed: true))
        XCTAssertNil(policy.update(target: large, now: 0.2, allowed: true))
        XCTAssertNil(policy.update(target: large, now: 0.34, allowed: true))
        XCTAssertEqual(policy.update(target: large, now: 0.351, allowed: true), large)
    }

    func testInactiveStageHidesImmediatelyAndReentrySettlesAgain() {
        var policy = WindowFollowPolicy()
        let valid = target()
        XCTAssertNil(policy.update(target: valid, now: 0, allowed: true))
        XCTAssertEqual(policy.update(target: valid, now: 0.2, allowed: true), valid)
        XCTAssertNil(policy.update(target: valid, now: 0.21, allowed: false))
        XCTAssertNil(policy.update(target: valid, now: 1, allowed: false))
        XCTAssertNil(policy.update(target: valid, now: 2, allowed: true))
        XCTAssertNil(policy.update(target: valid, now: 2.14, allowed: true))
        XCTAssertEqual(policy.update(target: valid, now: 2.151, allowed: true), valid)
    }

    func testNormalTargetsWorkOnScreensLeftAndAboveMainDisplay() {
        for display in [CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                        CGRect(x: 0, y: 900, width: 1920, height: 1080)] {
            let frame = CGRect(x: display.minX + 100, y: display.minY + 100,
                               width: 1000, height: 700)
            let result = WindowFollowPolicy.target(number: 3, frame: frame,
                visibleScreen: display, requestedScale: 1)
            XCTAssertEqual(result?.frame, frame)
            XCTAssertEqual(result?.area, frame)
            XCTAssertEqual(result?.scale, 1)
        }
    }

    func testWindowMovementDoesNotRestartEntryOrLoseVisibleFollowing() {
        var policy = WindowFollowPolicy()
        XCTAssertNil(policy.update(target: target(), now: 0, allowed: true))
        XCTAssertNil(policy.update(target: target(x: 300), now: 0.1, allowed: true))
        let moved = target(x: 500)
        XCTAssertEqual(policy.update(target: moved, now: 0.151, allowed: true), moved)
        let nearEdge = target(x: 1140)
        XCTAssertEqual(policy.update(target: nearEdge, now: 0.16, allowed: true), nearEdge)
    }

    func testVisibleWindowResizingDoesNotIntroduceAHideDelay() {
        var policy = WindowFollowPolicy()
        let initial = target()
        XCTAssertNil(policy.update(target: initial, now: 0, allowed: true))
        XCTAssertEqual(policy.update(target: initial, now: 0.2, allowed: true), initial)
        let resized = target(width: 500, height: 350)
        XCTAssertEqual(policy.update(target: resized, now: 0.21, allowed: true), resized)
    }

    func testHostSwitchRequiresNewSettlingInterval() {
        var policy = WindowFollowPolicy()
        let first = target()
        let second = target(number: 2)
        XCTAssertNil(policy.update(target: first, now: 0, allowed: true))
        XCTAssertEqual(policy.update(target: first, now: 0.2, allowed: true), first)
        XCTAssertNil(policy.update(target: second, now: 0.21, allowed: true))
        XCTAssertNil(policy.update(target: second, now: 0.35, allowed: true))
        XCTAssertEqual(policy.update(target: second, now: 0.361, allowed: true), second)
    }

    func testShortRepeatedMissingSamplesDoNotFlashTheWidgetBackOn() {
        var policy = WindowFollowPolicy()
        let valid = target()
        XCTAssertNil(policy.update(target: valid, now: 0, allowed: true))
        XCTAssertEqual(policy.update(target: valid, now: 0.2, allowed: true), valid)
        for index in 0..<5 {
            let now = 1 + Double(index) * 0.2
            XCTAssertNil(policy.update(target: nil, now: now, allowed: true))
            XCTAssertNil(policy.update(target: valid, now: now + 0.05, allowed: true))
            XCTAssertNil(policy.update(target: valid, now: now + 0.14, allowed: true))
        }
        XCTAssertEqual(policy.update(target: valid, now: 2.001, allowed: true), valid)
    }

    func testClockRollbackRestartsSettlingAndNonfiniteTimeHides() {
        var policy = WindowFollowPolicy()
        let valid = target()
        XCTAssertNil(policy.update(target: valid, now: 100, allowed: true))
        XCTAssertNil(policy.update(target: valid, now: 99, allowed: true))
        XCTAssertEqual(policy.update(target: valid, now: 99.151, allowed: true), valid)
        XCTAssertNil(policy.update(target: valid, now: .nan, allowed: true))
        XCTAssertNil(policy.update(target: valid, now: 100, allowed: true))
    }
}
