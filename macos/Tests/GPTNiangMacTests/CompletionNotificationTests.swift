import XCTest
import AppKit
import GPTNiangCore
@testable import GPTNiangMac

final class CompletionNotificationTests: XCTestCase {
    @MainActor func testDefaultsAndNotificationPreferencesPreserveExistingValues() throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: data) }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let file = data.appendingPathComponent("preferences.json")
        try Data(#"{"scale":0.6,"volume":0.37,"x":0.25,"followCodex":true,"futureSetting":"keep"}"#.utf8).write(to: file)
        let model = WidgetModel(dataDirectory: data, resources: data)
        XCTAssertFalse(model.completionEnabled)
        model.completionEnabled = true; model.savePreferences()
        let restored = WidgetModel(dataDirectory: data, resources: data)
        XCTAssertTrue(restored.completionEnabled)
        XCTAssertEqual(restored.scale, 0.6); XCTAssertEqual(restored.volume, 0.37); XCTAssertEqual(restored.x, 0.25)
        let values = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        XCTAssertEqual(values?["futureSetting"] as? String, "keep")
    }
    @MainActor func testCompletionUsesFixedTwoLinesWithoutQuotaRefreshAndManualTakeoverClearsItsMode() {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: data) }
        let model = WidgetModel(dataDirectory: data, resources: data)
        model.showCompletion()
        XCTAssertTrue(model.bubble); XCTAssertTrue(model.isCompletionMessage)
        XCTAssertEqual(model.message?.components(separatedBy: "\n").count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("refresh.flag").path))
        model.showQuota(); XCTAssertFalse(model.isCompletionMessage); XCTAssertNil(model.message)
        model.showCompletion(); model.hideBubble(); XCTAssertFalse(model.bubble); XCTAssertFalse(model.isCompletionMessage)
    }
}
