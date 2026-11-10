// Standalone checks for CommandLineTools-only installations without XCTest.
// Compile alongside the actual core sources; no copied production logic.
import Foundation
extension Bundle { static var module: Bundle { .main } }

@main struct VerifyAlertCore {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        let now = Date(timeIntervalSince1970: 10000)
        func snapshot(_ value: Double, account: String? = "anonymous", query: Bool = true,
                      observed: Double = 10000000, minutes: Int = 300, reset: Double? = nil) -> UsageSnapshot {
            UsageSnapshot(ok: true, queryOk: query, observedAt: observed,
                          windows: [QuotaWindow(minutes: minutes, remaining: value, resetsAt: reset)], accountKey: account)
        }
        var preferences = AlertPreferences(), state = QuotaAlertState()
        check(state.evaluate(snapshot(0), preferences: preferences, now: now).isEmpty, "disabled defaults")
        check(!preferences.completionEnabled && !preferences.soundEnabled, "opt-in defaults")
        preferences.shortEnabled = true; preferences.weekEnabled = true
        check(state.evaluate(snapshot(21), preferences: preferences, now: now).isEmpty, "above threshold")
        check(state.evaluate(snapshot(20), preferences: preferences, now: now).count == 1, "threshold inclusive")
        state = try JSONDecoder().decode(QuotaAlertState.self, from: JSONEncoder().encode(state))
        check(state.evaluate(snapshot(19), preferences: preferences, now: now).isEmpty, "restart deduplication")
        check(state.evaluate(snapshot(0), preferences: preferences, now: now).first?.exhausted == true, "exhaustion followup")
        check(state.evaluate(snapshot(0), preferences: preferences, now: now).isEmpty, "no exhaustion spam")
        _ = state.evaluate(snapshot(21), preferences: preferences, now: now)
        check(state.evaluate(snapshot(20), preferences: preferences, now: now).count == 1, "recovery rearms")
        check(state.evaluate(snapshot(10, account: "other"), preferences: preferences, now: now).count == 1, "account isolation")
        let unchanged = state
        for invalid in [snapshot(0, account: nil), snapshot(0, query: false), snapshot(0, observed: 1),
                        snapshot(-1), snapshot(.nan), snapshot(0, reset: 9000), snapshot(0, observed: 11000000)] {
            check(state.evaluate(invalid, preferences: preferences, now: now).isEmpty, "invalid or stale suppressed")
            check(state == unchanged, "invalid reply must not mutate state")
        }
        preferences.shortThreshold = 10
        check(state.evaluate(snapshot(15), preferences: preferences, now: now).isEmpty, "new threshold evaluation")
        check(state.evaluate(snapshot(10), preferences: preferences, now: now).count == 1, "new threshold crossing")
        let mixed = UsageSnapshot(ok: true, queryOk: true, observedAt: 10000000, windows: [
            QuotaWindow(minutes: 60, remaining: 10), QuotaWindow(minutes: 300, remaining: 10),
            QuotaWindow(minutes: 10080, remaining: 10), QuotaWindow(minutes: 43200, remaining: 10),
            QuotaWindow(remaining: 0, kind: "individual")], accountKey: "mixed")
        check(state.evaluate(mixed, preferences: preferences, now: now).map { $0.window.minutes } == [60,10080], "actual periods only")
        check(state.evaluate(snapshot(0, minutes: 43200), preferences: preferences, now: now).isEmpty, "monthly is not weekly")
        var cycle = QuotaAlertState()
        check(cycle.evaluate(snapshot(0, reset: 11000), preferences: preferences, now: now).count == 1, "first cycle")
        check(cycle.evaluate(snapshot(0, observed: 12000000, reset: 13000), preferences: preferences,
                             now: Date(timeIntervalSince1970: 12000)).count == 1, "reset rollover")
        preferences.shortThreshold = -1; preferences.weekThreshold = 1000; preferences.validate()
        check(preferences.shortThreshold == 1 && preferences.weekThreshold == 99, "bounds")
        var queue = AlertBubbleQueue()
        queue.append("a", now: now); queue.append("a", now: now); queue.append("b", now: now)
        check(queue.take(now: now, visible: false, busy: false) == nil, "hidden suppression")
        check(queue.take(now: now, visible: true, busy: true) == nil, "interaction deferral")
        check(queue.take(now: now, visible: true, busy: false) == "a\nb", "merged delivery")
        check(queue.take(now: now, visible: true, busy: false) == nil, "single delivery")
        queue.append("old", now: now); queue.append("new", now: now.addingTimeInterval(60))
        check(queue.take(now: now.addingTimeInterval(121), visible: true, busy: false) == "new", "per-event expiry")
        queue.append("disabled", now: now); queue.clear()
        check(queue.take(now: now, visible: true, busy: false) == nil, "disable clears pending")
        let data = Data(#"{"ok":true,"queryOk":true,"observedAt":10000000,"windows":[{"minutes":300,"remaining":12}],"accountKey":"hash"}"#.utf8)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        check(decoded.accountKey == "hash" && decoded.windows.count == 1, "backend fingerprint decoding")
        let legacy = Data(#"{"shortEnabled":true,"weekEnabled":true,"shortThreshold":27,"weekThreshold":9,"completionEnabled":true,"soundEnabled":true}"#.utf8)
        var migrated = try JSONDecoder().decode(AlertPreferences.self, from: legacy)
        check(migrated.shortEnabled && migrated.weekEnabled && migrated.completionEnabled && migrated.soundEnabled, "old toggles preserved")
        check(migrated.shortThreshold == 27 && migrated.weekThreshold == 9 && !migrated.completionPopupEnabled, "old thresholds preserved; popup opt-in")
        migrated.completionPopupEnabled = true
        let roundtrip = try JSONDecoder().decode(AlertPreferences.self, from: JSONEncoder().encode(migrated))
        check(roundtrip == migrated, "new setting round trip")
        for sound in [false, true] {
            for popup in [false, true] {
                migrated.soundEnabled = sound; migrated.completionPopupEnabled = popup
                check(CompletionPresentation.shouldPopup(preferences: migrated, followCodex: true, hostFrontmost: false, mainVisible: false) == popup, "popup independent of audio")
                check(!CompletionPresentation.shouldPopup(preferences: migrated, followCodex: false, hostFrontmost: false, mainVisible: true), "desktop mode unaffected")
                check(!CompletionPresentation.shouldPopup(preferences: migrated, followCodex: true, hostFrontmost: true, mainVisible: true), "foreground main widget has no duplicate")
            }
        }
        var life = CompletionPopupLifetime()
        life.record(count: 1, now: 100)
        check(life.visible(now: 105.99) && !life.visible(now: 106), "six second lifetime")
        life.record(count: 2, now: 104)
        check(life.count == 3 && life.visible(now: 109) && !life.visible(now: 110), "merged count extends deadline")
        life.record(count: 1, now: 111)
        check(life.count == 1, "expired batch starts fresh")
        life.dismiss(); check(!life.visible(now: 111), "dismiss cancels presentation")
        let screens = [CGRect(x: 0, y: 80, width: 1440, height: 820), CGRect(x: -1920, y: -300, width: 1920, height: 1080), CGRect(x: 0, y: 0, width: 250, height: 200)]
        for screen in screens {
            let frame = WidgetPlacement.completionFrame(area: screen, scale: 2.5)!
            check(screen.contains(frame), "popup stays within visible screen")
            check(abs(frame.maxX - (screen.maxX - 16)) < 0.01 && abs(frame.minY - (screen.minY + 16)) < 0.01, "right-bottom dock-safe margin")
        }
        check(WidgetPlacement.completionFrame(area: .zero, scale: 1) == nil, "invalid screen rejected")
        check(!WindowFollowVisibility.keepDuringMissingHost(appHidden: false, confirmedMissing: true, missingFor: 0), "confirmed minimized host hides immediately")
        check(!WindowFollowVisibility.keepDuringMissingHost(appHidden: true, confirmedMissing: false, missingFor: 0), "hidden app hides immediately")
        check(WindowFollowVisibility.keepDuringMissingHost(appHidden: false, confirmedMissing: false, missingFor: 0), "uncertain metadata keeps anti-flicker grace")
        check(WindowFollowVisibility.keepDuringMissingHost(appHidden: false, confirmedMissing: false, missingFor: 0.74), "grace before boundary")
        check(!WindowFollowVisibility.keepDuringMissingHost(appHidden: false, confirmedMissing: false, missingFor: 0.75), "uncertain metadata grace is bounded")
        check(!WindowFollowVisibility.keepDuringMissingHost(appHidden: false, confirmedMissing: false, missingFor: -1), "invalid interval cannot extend grace")
        var cadence = WindowFollowCadence()
        check(cadence.discover(now: 0) && !cadence.discover(now: 0.1), "regular discovery remains bounded")
        check(cadence.discover(now: 0.1, force: true), "lost cached host can trigger immediate alternate-window discovery")
        print("Alert core regression checks: \(checks) passed")
    }
}
