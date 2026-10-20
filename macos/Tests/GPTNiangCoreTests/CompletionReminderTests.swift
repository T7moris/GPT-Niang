import XCTest
import GPTNiangCore
final class CompletionReminderTests: XCTestCase {
    func testCoalescingAndLateEventsDoNotReplay() {
        var s = CompletionReminderState(); s.receive(endedAt: 10); s.show(.background, now: 11); s.receive(endedAt: 12)
        XCTAssertEqual(s.deadline, 16); s.dismiss(now: 13); s.receive(endedAt: 12); XCTAssertFalse(s.pending)
    }
    func testPauseKeepsPendingAndRestartsReadableInterval() {
        var s = CompletionReminderState(); s.receive(endedAt: 1); s.show(.foreground, now: 2, openingDelay: 0.52); s.pause()
        XCTAssertTrue(s.pending); s.show(.background, now: 10, openingDelay: 0.52); XCTAssertEqual(s.deadline, 15.52, accuracy: 0.001)
    }
    func testSurfaceCannotStartWithoutPendingAndDismissClearsIt() {
        var s = CompletionReminderState(); s.show(.background, now: 1); XCTAssertNil(s.surface)
        s.receive(endedAt: 2); s.show(.background, now: 3); s.dismiss(now: 4); XCTAssertNil(s.surface); XCTAssertFalse(s.pending)
    }
}
