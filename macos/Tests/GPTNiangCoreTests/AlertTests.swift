import XCTest
@testable import GPTNiangCore

final class AlertTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10000)
    private func sample(_ remaining: Double, account: String? = "fingerprint", minutes: Int = 300,
                        queryOK: Bool = true, observed: Double = 10000000, reset: Double? = 11000) -> UsageSnapshot {
        UsageSnapshot(ok: true, queryOk: queryOK, observedAt: observed,
                      windows: [QuotaWindow(minutes: minutes, remaining: remaining, resetsAt: reset)], accountKey: account)
    }
    private var enabled: AlertPreferences { var p = AlertPreferences(); p.shortEnabled = true; p.weekEnabled = true; return p }
    func testThresholdExhaustionRecoveryAndRestartDeduplication() throws {
        var state = QuotaAlertState()
        XCTAssertTrue(state.evaluate(sample(21), preferences: enabled, now: now).isEmpty)
        XCTAssertEqual(state.evaluate(sample(20), preferences: enabled, now: now).count, 1)
        state = try JSONDecoder().decode(QuotaAlertState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(state.evaluate(sample(19), preferences: enabled, now: now).isEmpty)
        XCTAssertTrue(state.evaluate(sample(1), preferences: enabled, now: now).isEmpty)
        XCTAssertEqual(state.evaluate(sample(0), preferences: enabled, now: now).first?.exhausted, true)
        XCTAssertTrue(state.evaluate(sample(0), preferences: enabled, now: now).isEmpty)
        _ = state.evaluate(sample(50), preferences: enabled, now: now)
        XCTAssertEqual(state.evaluate(sample(10), preferences: enabled, now: now).count, 1)
    }
    func testAccountsThresholdChangesAndInvalidData() {
        var state = QuotaAlertState(), prefs = enabled
        XCTAssertEqual(state.evaluate(sample(15), preferences: prefs, now: now).count, 1)
        XCTAssertEqual(state.evaluate(sample(15, account: "other"), preferences: prefs, now: now).count, 1)
        XCTAssertTrue(state.evaluate(sample(15, account: nil), preferences: prefs, now: now).isEmpty)
        prefs.shortThreshold = 10
        XCTAssertTrue(state.evaluate(sample(15), preferences: prefs, now: now).isEmpty)
        XCTAssertEqual(state.evaluate(sample(10), preferences: prefs, now: now).count, 1)
        let unchanged = state
        for snapshot in [sample(0, queryOK: false), sample(0, observed: 1), sample(0, reset: 9999), sample(-1), sample(.nan)] {
            XCTAssertTrue(state.evaluate(snapshot, preferences: prefs, now: now).isEmpty)
            XCTAssertEqual(state, unchanged)
        }
    }
    func testActualWindowSelectionAndOptionalReset() {
        var state = QuotaAlertState()
        let mixed = UsageSnapshot(ok: true, queryOk: true, observedAt: 10000000, windows: [
            QuotaWindow(minutes: 60, remaining: 10), QuotaWindow(minutes: 300, remaining: 10),
            QuotaWindow(minutes: 10080, remaining: 10), QuotaWindow(minutes: 43200, remaining: 10),
            QuotaWindow(remaining: 10, kind: "individual")], accountKey: "account")
        XCTAssertEqual(state.evaluate(mixed, preferences: enabled, now: now).map { $0.window.minutes }, [60, 10080])
        XCTAssertEqual(QuotaAlertState().latches.count, 0)
        var other = QuotaAlertState()
        XCTAssertTrue(other.evaluate(sample(0, minutes: 43200), preferences: enabled, now: now).isEmpty)
        XCTAssertEqual(other.evaluate(sample(0, reset: nil), preferences: enabled, now: now).count, 1)
    }
    func testResetRolloverDoesNotDependOnObservingAFullBalance() {
        var state = QuotaAlertState()
        _ = state.evaluate(sample(0), preferences: enabled, now: now)
        let later = Date(timeIntervalSince1970: 12000)
        let fresh = sample(0, observed: 12000000, reset: 13000)
        XCTAssertEqual(state.evaluate(fresh, preferences: enabled, now: later).count, 1)
        XCTAssertTrue(state.evaluate(fresh, preferences: enabled, now: later).isEmpty)
    }
    func testDisabledDefaultsAndThresholdBounds() throws {
        var state = QuotaAlertState(), prefs = AlertPreferences()
        XCTAssertTrue(state.evaluate(sample(0), preferences: prefs, now: now).isEmpty)
        XCTAssertFalse(prefs.completionEnabled); XCTAssertFalse(prefs.soundEnabled)
        prefs.shortThreshold = -1; prefs.weekThreshold = 1000; prefs.validate()
        XCTAssertEqual(prefs.shortThreshold, 1); XCTAssertEqual(prefs.weekThreshold, 99)
        let decoded = try JSONDecoder().decode(AlertPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(prefs, decoded)
    }
    func testBubbleDefersDuringUserInteractionAndHiddenWindowsMergesAndExpires() {
        var queue = AlertBubbleQueue()
        queue.append("first", now: now); queue.append("first", now: now); queue.append("second", now: now)
        XCTAssertNil(queue.take(now: now, visible: false, busy: false))
        XCTAssertNil(queue.take(now: now, visible: true, busy: true))
        XCTAssertEqual(queue.take(now: now, visible: true, busy: false), "first\nsecond")
        XCTAssertNil(queue.take(now: now, visible: true, busy: false))
        queue.append("old", now: now)
        XCTAssertNil(queue.take(now: now.addingTimeInterval(121), visible: true, busy: false))
        queue.append("disabled", now: now); queue.clear()
        XCTAssertNil(queue.take(now: now, visible: true, busy: false))
    }
    func testLegacyPreferencesPreserveIndependentControlsAndPopupDefaultsOff() throws {
        let legacy = Data(#"{"shortEnabled":true,"weekEnabled":true,"shortThreshold":27,"weekThreshold":9,"completionEnabled":true,"soundEnabled":true}"#.utf8)
        var prefs = try JSONDecoder().decode(AlertPreferences.self, from: legacy)
        XCTAssertTrue(prefs.shortEnabled && prefs.weekEnabled && prefs.completionEnabled && prefs.soundEnabled)
        XCTAssertEqual(prefs.shortThreshold, 27); XCTAssertEqual(prefs.weekThreshold, 9)
        XCTAssertFalse(prefs.completionPopupEnabled)
        for sound in [false, true] {
            for popup in [false, true] {
                prefs.soundEnabled = sound; prefs.completionPopupEnabled = popup
                XCTAssertEqual(CompletionPresentation.shouldPopup(preferences: prefs, followCodex: true, hostFrontmost: false, mainVisible: false), popup)
                XCTAssertFalse(CompletionPresentation.shouldPopup(preferences: prefs, followCodex: false, hostFrontmost: false, mainVisible: true))
                XCTAssertFalse(CompletionPresentation.shouldPopup(preferences: prefs, followCodex: true, hostFrontmost: true, mainVisible: true))
            }
        }
    }
    func testPopupLifetimeMergesAndExtendsWithoutCarryingExpiredCount() {
        var state = CompletionPopupLifetime()
        state.record(count: 1, now: 100); XCTAssertFalse(state.visible(now: 106))
        state.record(count: 2, now: 104); XCTAssertEqual(state.count, 3)
        XCTAssertTrue(state.visible(now: 109)); XCTAssertFalse(state.visible(now: 110))
        state.record(count: 1, now: 111); XCTAssertEqual(state.count, 1)
        state.dismiss(); XCTAssertFalse(state.visible(now: 111))
    }

}
