import XCTest
import Foundation
import Darwin
import GPTNiangUpdate
@testable import GPTNiangMac

final class UpdateReadinessTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manifest = root.appendingPathComponent("Backend/.codex-plugin/plugin.json")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":"1.3.4"}"#.utf8).write(to: manifest)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    private func record(_ root: URL, token: String = "current", pid: Int32 = getpid(), parent: Int32 = 0,
                        at: Date = Date(), version: String? = "1.3.4", busy: Bool = false) throws {
        let owner: [String: Any] = ["token": token, "pid": pid, "parentPid": parent]
        var status = owner
        status["at"] = at.timeIntervalSince1970 * 1000; status["version"] = version; status["busy"] = busy
        for (name, value) in [("worker.lock", owner), ("worker-status.json", status)] {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name), options: .atomic)
        }
    }
    private func store(_ root: URL, phase: UpdatePhase = .replaced) throws -> UpdateStore {
        let store = try UpdateStore(app: root.appendingPathComponent("GPTNiangMac.app"), data: root.appendingPathComponent("state"))
        var journal = UpdateJournal(token: UUID().uuidString, app: store.app, data: store.data,
            version: "1.3.4", oldVersion: "1.3.3", hash: "fixture", parentPID: getpid())
        journal.phase = phase; try store.save(journal)
        return store
    }

    @MainActor func testSlowStartupWaitsForHeartbeatWithoutWaitingForQuotaSuccess() throws {
        let root = try fixture(), model = WidgetModel(dataDirectory: root, resources: root)
        let now = Date()
        XCTAssertFalse(model.workerHealthy(version: "1.3.4", now: now))
        try record(root, at: now, busy: true)
        // Initialization is sufficient: a slow network or logged-out account must not force rollback.
        XCTAssertTrue(model.workerHealthy(version: "1.3.4", now: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("status.json").path))
    }
    @MainActor func testHeartbeatMustBeFreshAndNotFromFuture() throws {
        let root = try fixture(), model = WidgetModel(dataDirectory: root, resources: root)
        let now = Date(); try record(root, at: now)
        XCTAssertTrue(model.workerHealthy(version: "1.3.4", now: now.addingTimeInterval(4)))
        XCTAssertFalse(model.workerHealthy(version: "1.3.4", now: now.addingTimeInterval(5)))
        XCTAssertFalse(model.workerHealthy(version: "1.3.4", now: now.addingTimeInterval(-1)))
    }
    @MainActor func testOwnerTokenPIDAndParentMustMatchHeartbeat() throws {
        let root = try fixture(), model = WidgetModel(dataDirectory: root, resources: root)
        let now = Date(); try record(root, at: now)
        let changedOwners: [[String: Any]] = [["token": "another", "pid": getpid(), "parentPid": 0],
                        ["token": "current", "pid": getpid() + 1, "parentPid": 0],
                        ["token": "current", "pid": getpid(), "parentPid": getpid()]]
        for changed in changedOwners {
            try JSONSerialization.data(withJSONObject: changed).write(to: root.appendingPathComponent("worker.lock"))
            XCTAssertFalse(model.workerHealthy(version: "1.3.4", now: now, isAlive: { _ in true }))
        }
        try record(root, token: "", at: now)
        XCTAssertFalse(model.workerHealthy(version: "1.3.4", now: now))
    }
    @MainActor func testDeadWorkerAndDeadParentCannotConfirmReadiness() throws {
        let root = try fixture(), model = WidgetModel(dataDirectory: root, resources: root)
        let now = Date(); try record(root, at: now)
        XCTAssertFalse(model.workerHealthy(version: "1.3.4", now: now, isAlive: { _ in false }))
        try record(root, parent: 12345, at: now)
        XCTAssertFalse(model.workerHealthy(version: "1.3.4", now: now, isAlive: { $0 == getpid() }))
        XCTAssertTrue(model.workerHealthy(version: "1.3.4", now: now, isAlive: { _ in true }))
        try record(root, pid: 0, at: now)
        XCTAssertFalse(model.workerHealthy(version: "1.3.4", now: now, isAlive: { _ in XCTFail("Invalid PID"); return true }))
    }
    @MainActor func testLegacyWrongAndMissingBackendVersionsAreRejected() throws {
        let root = try fixture(), model = WidgetModel(dataDirectory: root, resources: root)
        let now = Date()
        let versions: [String?] = [nil, "1.3.3", ""]
        for version in versions {
            try record(root, at: now, version: version)
            XCTAssertFalse(model.workerHealthy(version: "1.3.4", now: now))
        }
        try record(root, at: now)
        XCTAssertFalse(model.workerHealthy(version: "1.3.5", now: now))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Backend/.codex-plugin/plugin.json"))
        let missing = WidgetModel(dataDirectory: root, resources: root)
        XCTAssertFalse(missing.workerHealthy(version: "1.3.4", now: now))
    }
    @MainActor func testMissingAndMalformedWorkerRecordsAreRejected() throws {
        let root = try fixture(), model = WidgetModel(dataDirectory: root, resources: root)
        for name in ["worker.lock", "worker-status.json"] {
            try record(root)
            try FileManager.default.removeItem(at: root.appendingPathComponent(name))
            XCTAssertFalse(model.workerHealthy(version: "1.3.4"))
            try Data("{broken".utf8).write(to: root.appendingPathComponent(name))
            XCTAssertFalse(model.workerHealthy(version: "1.3.4"))
        }
    }
    @MainActor func testConfirmationRemainsPendingUntilReadyThenWritesTransactionIdentity() throws {
        let active = try store(fixture()), health = active.data.appendingPathComponent("mac-update-health.json")
        XCTAssertFalse(NativeUpdater.confirmLaunch(data: active.data, app: active.app, version: "1.3.4", workerReady: { false }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: health.path))
        XCTAssertTrue(NativeUpdater.confirmLaunch(data: active.data, app: active.app, version: "1.3.4", workerReady: { true }))
        let ready = try XCTUnwrap(UpdateFiles.read(UpdateHealth.self, at: health)), journal = try XCTUnwrap(active.journal())
        XCTAssertEqual(ready.token, journal.token); XCTAssertEqual(ready.version, journal.version)
        XCTAssertEqual(ready.appPath, active.app.path); XCTAssertEqual(ready.pid, getpid())
    }
    @MainActor func testFailedConfirmationWriteCanRetry() throws {
        let active = try store(fixture()), health = active.data.appendingPathComponent("mac-update-health.json")
        XCTAssertFalse(NativeUpdater.confirmLaunch(data: active.data, app: active.app, version: "1.3.4", workerReady: { true }, writeHealth: { _, _ in
            throw NSError(domain: "fixture", code: 1)
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: health.path))
        XCTAssertTrue(NativeUpdater.confirmLaunch(data: active.data, app: active.app, version: "1.3.4", workerReady: { true }))
        XCTAssertNotNil(try UpdateFiles.read(UpdateHealth.self, at: health))
    }
    @MainActor func testWrongAppVersionOrPhaseCannotConfirm() throws {
        let root = try fixture(), active = try store(root)
        XCTAssertFalse(NativeUpdater.confirmLaunch(data: active.data, app: active.app, version: "1.3.3", workerReady: { true }))
        XCTAssertFalse(NativeUpdater.confirmLaunch(data: active.data, app: root.appendingPathComponent("Other.app"), version: "1.3.4", workerReady: { true }))
        _ = try store(root, phase: .prepared)
        XCTAssertFalse(NativeUpdater.confirmLaunch(data: active.data, app: active.app, version: "1.3.4", workerReady: { true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.data.appendingPathComponent("mac-update-health.json").path))
    }
    @MainActor func testNoPendingOrCompletedTransactionNeedsNoWorkerReadsOrHealthWrite() throws {
        let root = try fixture(), data = root.appendingPathComponent("state"), app = root.appendingPathComponent("GPTNiangMac.app")
        func unexpectedReadiness() -> Bool { XCTFail("No pending transaction"); return false }
        XCTAssertTrue(NativeUpdater.confirmLaunch(data: data, app: app, version: "1.3.4", workerReady: unexpectedReadiness))
        _ = try store(root, phase: .committed)
        XCTAssertTrue(NativeUpdater.confirmLaunch(data: data, app: app, version: "1.3.4", workerReady: unexpectedReadiness))
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("mac-update-health.json").path))
    }
}
