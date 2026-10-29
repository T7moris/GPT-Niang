import XCTest
import GPTNiangCore
@testable import GPTNiangMac

@MainActor private final class FakeAlertNotifications: AlertNotifications {
    var allowed = false
    var requests = 0
    var deliveries: [String] = []
    func authorize(request: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        if request { requests += 1 }; completion(allowed)
    }
    func send(title: String, body: String, completion: @escaping @MainActor (Bool) -> Void) {
        deliveries.append(body); completion(true)
    }
}
final class AlertCoordinatorTests: XCTestCase {
    @MainActor private func makeModel(_ t: String) throws -> WidgetModel {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("niang-alert-" + t + UUID().uuidString)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        return WidgetModel(dataDirectory: data, resources: data)
    }
    @MainActor func testDeniedNotificationPermissionStillShowsBubbleAndPersistsDeduplication() async throws {
        let model = try makeModel("denied")
        defer { try? FileManager.default.removeItem(at: model.dataDirectory) }
        model.alertPreferences.shortEnabled = true
        model.snapshot = UsageSnapshot(ok: true, queryOk: true, observedAt: Date().timeIntervalSince1970 * 1000,
            windows: [QuotaWindow(minutes: 300, remaining: 10)], accountKey: "anonymous")
        let notifications = FakeAlertNotifications()
        let tested = AlertCoordinator(model: model, notifications: notifications)
        tested.windowVisible = true; tested.configure()
        XCTAssertTrue(model.alertPermissionDenied); XCTAssertTrue(model.bubble)
        XCTAssertNotNil(model.message); XCTAssertEqual(notifications.requests, 1); XCTAssertTrue(notifications.deliveries.isEmpty)
        model.hideBubble()
        let restarted = AlertCoordinator(model: model, notifications: notifications)
        restarted.windowVisible = true; restarted.configure()
        XCTAssertFalse(model.bubble)
        XCTAssertTrue(notifications.deliveries.isEmpty)
    }
    @MainActor func testAuthorizedDeliveryDefersBubbleWhileBusyAndPreservesUnknownPreferences() async throws {
        let model = try makeModel("authorized")
        defer { try? FileManager.default.removeItem(at: model.dataDirectory) }
        let prefs = model.dataDirectory.appendingPathComponent("preferences.json")
        try Data(#"{"futurePreference":"keep"}"#.utf8).write(to: prefs)
        model.alertPreferences.weekEnabled = true; model.alertPreferences.weekThreshold = 12
        model.savePreferences()
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: prefs)) as? [String: Any]
        XCTAssertEqual(saved?["futurePreference"] as? String, "keep")
        let reloaded = WidgetModel(dataDirectory: model.dataDirectory, resources: model.dataDirectory)
        XCTAssertEqual(reloaded.alertPreferences.weekThreshold, 12); XCTAssertTrue(reloaded.alertPreferences.weekEnabled)
        XCTAssertFalse(reloaded.alertPreferences.shortEnabled); XCTAssertFalse(reloaded.alertPreferences.soundEnabled)
        let notifications = FakeAlertNotifications(); notifications.allowed = true
        let coordinator = AlertCoordinator(model: model, notifications: notifications)
        model.snapshot = UsageSnapshot(ok: true, queryOk: true, observedAt: Date().timeIntervalSince1970 * 1000,
            windows: [QuotaWindow(minutes: 10080, remaining: 12)], accountKey: "anonymous")
        coordinator.windowVisible = true; coordinator.windowBusy = true; coordinator.configure()
        XCTAssertEqual(notifications.deliveries.count, 1); XCTAssertFalse(model.bubble)
        coordinator.windowBusy = false; coordinator.tick()
        XCTAssertTrue(model.bubble); XCTAssertEqual(notifications.deliveries.count, 1)
        model.hideBubble(); model.alertPreferences.weekEnabled = false; coordinator.configure()
        XCTAssertFalse(model.bubble)
    }
    @MainActor func testHiddenCompletionSoundsImmediatelyButQueuedBubbleDoesNotReplaySound() async throws {
        let model = try makeModel("background-sound")
        defer { try? FileManager.default.removeItem(at: model.dataDirectory) }
        model.alertPreferences.completionEnabled = true; model.alertPreferences.soundEnabled = true; model.alertPreferences.completionSoundEnabled = true
        var tones = 0
        let coordinator = AlertCoordinator(model: model, notifications: FakeAlertNotifications(), playSound: { _ in tones += 1 })
        let event = try JSONSerialization.data(withJSONObject: ["events": [["threadId": "test", "eventId": "complete", "at": Date().timeIntervalSince1970 * 1000]]]) + Data([10])
        coordinator.windowVisible = false; coordinator.windowBusy = true; coordinator.consume(event)
        XCTAssertEqual(tones, 1); XCTAssertFalse(model.bubble)
        coordinator.consume(event); XCTAssertEqual(tones, 1)
        coordinator.windowVisible = true; coordinator.windowBusy = false; coordinator.tick()
        XCTAssertTrue(model.bubble); XCTAssertEqual(tones, 1)
        coordinator.stop()
    }

    @MainActor func testIndependentPopupAndSoundControlsAndNoReplayOnReturn() async throws {
        for sound in [false, true] {
            for popup in [false, true] {
                let model = try makeModel("popup-combinations")
                defer { try? FileManager.default.removeItem(at: model.dataDirectory) }
                model.followCodex = true
                model.alertPreferences.completionEnabled = true
                model.alertPreferences.completionPopupEnabled = popup
                model.alertPreferences.soundEnabled = sound; model.alertPreferences.completionSoundEnabled = sound
                var sounds = 0, presentations = 0
                let coordinator = AlertCoordinator(model: model, notifications: FakeAlertNotifications(), playSound: { _ in sounds += 1 })
                coordinator.presentCompletionPopup = { count in presentations += count.values.reduce(0, +); return true }
                let event = try JSONSerialization.data(withJSONObject: ["events": [["threadId": "test", "eventId": "one", "at": Date().timeIntervalSince1970 * 1000]]]) + Data([10])
                coordinator.windowVisible = false; coordinator.hostFrontmost = false
                coordinator.consume(event); coordinator.consume(event)
                XCTAssertEqual(sounds, sound ? 1 : 0); XCTAssertEqual(presentations, popup ? 1 : 0)
                coordinator.windowVisible = true; coordinator.hostFrontmost = true; coordinator.tick()
                XCTAssertEqual(model.bubble, !popup); XCTAssertEqual(sounds, sound ? 1 : 0)
                coordinator.stop()
            }
        }
    }

}
