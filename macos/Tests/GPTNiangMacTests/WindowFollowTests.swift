import AppKit
#if !WINDOW_FOLLOW_STANDALONE
import XCTest
@testable import GPTNiangMac

final class WindowFollowTests: XCTestCase {
    @MainActor func testStageManagerFullscreenAndMultipleDisplays() async {
        _ = WindowFollowRegression.run { passed, message, file, line in
            XCTAssertTrue(passed, message, file: file, line: line)
        }
    }
}
#else
// The same assertions can run on CommandLineTools-only Macs without XCTest.
@main
struct WindowFollowRegressionRunner {
    @MainActor static func main() {
        let count = WindowFollowRegression.run { passed, message, file, line in
            guard passed else { fatalError("FAIL: \(message)", file: file, line: line) }
        }
        print("PASS: \(count) window-follow regression checks")
    }
}
#endif

@MainActor
private enum WindowFollowRegression {
    static func run(check: (Bool, String, StaticString, UInt) -> Void) -> Int {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
            checks += 1
            check(value(), message, file, line)
        }
        let policy = WindowFollowPolicy()
        expect(policy.mayFollow(stageManager: true, hostActive: true, companionActive: false, frontmostOnAnotherScreen: false), "active host shown")
        expect(!policy.mayFollow(stageManager: true, hostActive: false, companionActive: false, frontmostOnAnotherScreen: false), "hide when same display changes stage")
        expect(policy.mayFollow(stageManager: true, hostActive: false, companionActive: false, frontmostOnAnotherScreen: true), "clicking a different display keeps companion visible")
        expect(policy.mayFollow(stageManager: false, hostActive: false, companionActive: false, frontmostOnAnotherScreen: false), "ordinary desktop keeps background follow")
        expect(policy.mayFollow(stageManager: true, hostActive: false, companionActive: true, frontmostOnAnotherScreen: false), "own settings do not dismiss companion")
        expect(WindowFollowPolicy.level(hostActive: true, companionActive: false) == .floating, "clicking active host cannot cover companion between polls")
        expect(WindowFollowPolicy.level(hostActive: false, companionActive: false) == .normal, "background companion preserves other apps ordering")
        expect(WindowFollowPolicy.level(hostActive: false, companionActive: true) == .floating, "companion settings keep widget above host")

        let screens = [CGRect(x: 0, y: 0, width: 1728, height: 1117),
                       CGRect(x: 1728, y: 0, width: 2560, height: 1440),
                       CGRect(x: -1440, y: -293, width: 1440, height: 2560)]
        for (index, screen) in screens.enumerated() {
            expect(WindowFollowPolicy.usableHost(screen, screens: screens), "fullscreen host on display \(index)")
        }
        expect(WindowFollowPolicy.usableHost(CGRect(x: 1789, y: 0, width: 1728, height: 1084), screens: screens), "observed external display host")
        expect(!WindowFollowPolicy.usableHost(CGRect(x: 9000, y: 0, width: 1728, height: 1084), screens: screens), "onscreen metadata outside displays is rejected")
        expect(!WindowFollowPolicy.usableHost(CGRect(x: 4260, y: 0, width: 1728, height: 1084), screens: screens), "mostly offscreen animation frame is rejected")
        expect(!WindowFollowPolicy.usableHost(CGRect(x: 0, y: 0, width: 180, height: 120), screens: screens), "Stage Manager thumbnail is rejected")
        expect(!WindowFollowPolicy.usableHost(CGRect(x: 0, y: 0, width: 2, height: 2), screens: screens), "temporary window is rejected")
        expect(!WindowFollowPolicy.usableHost(CGRect(x: CGFloat.infinity, y: 0, width: 900, height: 600), screens: screens), "nonfinite geometry is rejected")
        expect(!WindowFollowPolicy.usableHost(screens[0], screens: []), "no displays means hidden")
        expect(WindowFollowPolicy.screen(for: CGRect(x: 2000, y: 10, width: 1200, height: 800), screens: screens) == screens[1], "identify focus on external display")
        expect(WindowFollowPolicy.screen(for: CGRect(x: -1440, y: 0, width: 1000, height: 600), screens: screens) == screens[2], "identify portrait display")

        // Reproduction: Codex stays fullscreen on display 0 while clicking the
        // portrait display's desktop retracts its Stage Manager windows. Finder
        // is active but has no ordinary windows in the onscreen window list.
        var focus = FocusDisplayTracker()
        expect(focus.resolve(window: nil, screens: screens) == nil, "unknown focus does not invent a display")
        focus.recordInteraction(at: CGPoint(x: -1000, y: 500), screens: screens)
        let desktopScreen = focus.resolve(window: nil, screens: screens)
        expect(desktopScreen == screens[2], "windowless Finder retains the clicked desktop display")
        expect(policy.mayFollow(stageManager: true, hostActive: false, companionActive: false,
            frontmostOnAnotherScreen: desktopScreen != nil && desktopScreen != screens[0]),
            "retracting another display's stage keeps the fullscreen companion visible")
        expect(focus.resolve(window: nil, screens: screens) == screens[2], "repeated discovery retains desktop focus without another interaction")
        expect(focus.resolve(window: screens[1], screens: screens) == screens[1], "known active window takes precedence over interaction fallback")
        focus.recordInteraction(at: CGPoint(x: 800, y: 500), screens: screens)
        let sameScreen = focus.resolve(window: nil, screens: screens)
        expect(!policy.mayFollow(stageManager: true, hostActive: false, companionActive: false,
            frontmostOnAnotherScreen: sameScreen != nil && sameScreen != screens[0]),
            "another desktop click on host display still hides its retracted stage")
        expect(focus.resolve(window: nil, screens: [screens[1], screens[2]]) == nil, "removed display is not retained as focus")
        focus.recordInteraction(at: CGPoint(x: 9000, y: 9000), screens: screens)
        expect(focus.resolve(window: nil, screens: screens) == nil, "out-of-display interaction clears fallback")

        var geometry = HostGeometryStability()
        let home = CGRect(x: 0, y: 0, width: 1728, height: 1084)
        func accept(_ frame: CGRect, _ now: TimeInterval, drag: Bool = false) -> Bool {
            geometry.accept(number: 10, frame: frame, screens: screens, now: now, mouseDraggingHost: drag)
        }
        expect(accept(home, 0), "initial fullscreen window")
        expect(accept(home, 0.1), "ordinary clicks do not hide unchanged host")
        let sliding = home.offsetBy(dx: 1800, dy: 0)
        expect(!accept(sliding, 1), "hide on first cross-screen animation frame")
        expect(geometry.transitioning, "animation is distinguished from host disappearance")
        expect(!accept(sliding, 1.5), "paused swipe cannot place companion on neighbouring display")
        expect(!accept(sliding, 5), "even a long held swipe cannot move companion across screens")
        expect(!accept(home, 6), "cancelled swipe waits for geometry to settle")
        expect(!accept(home, 6.1), "do not flash during reversal")
        expect(accept(home, 6.31), "show at original display once cancelled swipe settles")
        expect(!geometry.transitioning, "transition ends after recovery")
        expect(accept(sliding, 7, drag: true), "real mouse drag can move between displays")
        expect(accept(sliding, 7.1), "releasing cross-screen drag does not hide panel")
        let restored = CGRect(x: 1900, y: 100, width: 1000, height: 700)
        expect(!accept(restored, 8), "hide during fullscreen exit geometry change")
        expect(accept(restored, 8.31), "resized normal window recovers on external display")

        expect(!WindowFollowPolicy.needsOrdering(host: 10, panel: 20, frontToBack: [30, 20, 10]), "already above host")
        expect(WindowFollowPolicy.needsOrdering(host: 10, panel: 20, frontToBack: [30, 10, 20]), "clicking same host restores relative order")
        expect(WindowFollowPolicy.needsOrdering(host: 10, panel: 20, frontToBack: [10]), "panel returning to fullscreen must be ordered")
        expect(!WindowFollowPolicy.needsOrdering(host: 10, panel: 20, frontToBack: [20, 30]), "do not reorder against an absent host")
        expect(WindowFollowPolicy.needsOrdering(host: 11, panel: 20, frontToBack: [11, 20, 10]), "switch to another host window")

        // Only an already tracked or actively mouse-dragged host may retain a
        // narrow screen strip. Initial thumbnails still use the original gate.
        let edge = CGRect(x: 100, y: -699, width: 900, height: 700)
        expect(!WindowFollowPolicy.usableHost(edge, screens: screens), "unknown thin host keeps original filtering")
        expect(WindowFollowPolicy.usableHost(edge, screens: screens, allowClipped: true), "tracked real host can be clipped at screen edge")
        expect(!WindowFollowPolicy.usableHost(edge.offsetBy(dx: 0, dy: -1), screens: [screens[0]], allowClipped: true), "fully offscreen tracked host stays hidden")
        expect(!WindowFollowPolicy.usableHost(CGRect(x: 0, y: 0, width: 180, height: 120), screens: screens, allowClipped: true), "clipping cannot promote thumbnails")
        expect(!WindowFollowPolicy.usableHost(CGRect(x: CGFloat.infinity, y: 0, width: 900, height: 700), screens: screens, allowClipped: true), "clipping cannot promote invalid geometry")
        var tracked = HostGeometryStability()
        expect(!tracked.isTracking(number: 10), "new geometry has no tracked host")
        _ = tracked.accept(number: 10, frame: home, screens: screens, now: 0, mouseDraggingHost: false)
        expect(tracked.isTracking(number: 10), "accepted host identity can retain clipping")
        expect(!tracked.isTracking(number: 11), "tracking does not bypass a different host's initial gate")

        _ = NSApplication.shared
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 378, height: 378),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = WindowFollowPolicy.collectionBehavior
        panel.animationBehavior = .none
        expect(panel.collectionBehavior.contains(.canJoinAllApplications), "participates with other apps in Stage Manager")
        expect(panel.collectionBehavior.contains(.fullScreenAuxiliary), "can accompany a fullscreen host")
        expect(panel.collectionBehavior.contains(.stationary), "no managed window slide during Space switching")
        expect(!panel.collectionBehavior.contains(.managed), "not a separate managed window")
        expect(!panel.collectionBehavior.contains(.primary), "does not create its own stage")
        expect(panel.level == .normal, "preserves normal level rather than covering unrelated apps")
        expect(panel.animationBehavior == .none, "hiding does not animate a second time")
        panel.close()
        return checks
    }
}
