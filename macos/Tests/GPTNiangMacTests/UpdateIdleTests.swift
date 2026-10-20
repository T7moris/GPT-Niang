import XCTest
import Foundation
import Darwin
@testable import GPTNiangMac

final class UpdateIdleTests: XCTestCase {
    @MainActor private func fixture() throws -> (URL, WidgetModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manifest = root.appendingPathComponent("Backend/.codex-plugin/plugin.json")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":"1.3.4"}"#.utf8).write(to: manifest)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (root, WidgetModel(dataDirectory: root, resources: root))
    }
    private func write(_ root: URL, _ name: String, _ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name), options: .atomic)
    }
    private func record(_ root: URL, pid: Int32 = 1001, parent: Int32 = 0, at: Date = Date(),
                        busy: Bool? = false, version: String? = "1.3.4") throws {
        let owner: [String: Any] = ["token": "current", "pid": pid, "parentPid": parent]
        var status = owner
        status["at"] = at.timeIntervalSince1970 * 1000; status["busy"] = busy; status["version"] = version
        try write(root, "worker.lock", owner); try write(root, "worker-status.json", status)
    }

    @MainActor func testOwnedChildCannotBeIdleBeforeItsMatchingMetadataIsReady() async throws {
        let (root, model) = try fixture(), executable = root.appendingPathComponent("node-fixture")
        try Data("#!/bin/sh\nprintf '%s' \"$$\" > \"$(dirname \"$0\")/child-pid\"\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let previous = getenv("GPT_NIANG_NODE").map { String(cString: $0) }
        setenv("GPT_NIANG_NODE", executable.path, 1)
        defer {
            model.stop()
            if let previous { setenv("GPT_NIANG_NODE", previous, 1) } else { unsetenv("GPT_NIANG_NODE") }
        }
        model.tick()
        XCTAssertTrue(model.workerRunning); XCTAssertFalse(model.updateIdle)
        let pidFile = root.appendingPathComponent("child-pid")
        var childPID: Int32?
        for _ in 0..<200 {
            childPID = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0) }
            if childPID != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pid = try XCTUnwrap(childPID)
        try record(root, pid: pid, parent: getpid(), busy: true)
        XCTAssertFalse(model.updateIdle)
        try record(root, pid: pid, parent: getpid(), busy: false)
        XCTAssertTrue(model.updateIdle)
        try FileManager.default.removeItem(at: root.appendingPathComponent("worker.lock"))
        XCTAssertFalse(model.updateIdle) // A live orphan heartbeat still cannot certify this child.
        try record(root, pid: getpid(), busy: false)
        XCTAssertFalse(model.updateIdle) // Another idle writer cannot stand in for this startup.
    }
    @MainActor func testLiveWorkerRequiresExplicitIdleAndFreshHeartbeat() throws {
        let (root, model) = try fixture(), now = Date()
        let alive: (Int32) -> Bool = { $0 == 1001 }
        try record(root, at: now, busy: false)
        XCTAssertTrue(model.updateIsIdle(now: now, isAlive: alive))
        let busyStates: [Bool?] = [true, nil]
        for busy in busyStates {
            try record(root, at: now, busy: busy)
            XCTAssertFalse(model.updateIsIdle(now: now, isAlive: alive))
        }
        try record(root, at: now)
        XCTAssertFalse(model.updateIsIdle(now: now.addingTimeInterval(5), isAlive: alive))
        XCTAssertFalse(model.updateIsIdle(now: now.addingTimeInterval(-1), isAlive: alive))
        XCTAssertTrue(model.updateIsIdle(now: now.addingTimeInterval(4), isAlive: alive))
    }
    @MainActor func testMismatchedIdentityMissingStatusOrDeadParentCannotBeIdle() throws {
        let (root, model) = try fixture(), now = Date()
        let alive: (Int32) -> Bool = { $0 == 1001 || $0 == 2001 }
        let owners: [[String: Any]] = [["token": "other", "pid": 1001, "parentPid": 0],
            ["token": "current", "pid": 2001, "parentPid": 0], ["token": "current", "pid": 1001, "parentPid": 2001]]
        for owner in owners {
            try record(root, at: now); try write(root, "worker.lock", owner)
            XCTAssertFalse(model.updateIsIdle(now: now, isAlive: alive))
        }
        try record(root, at: now); try FileManager.default.removeItem(at: root.appendingPathComponent("worker-status.json"))
        XCTAssertFalse(model.updateIsIdle(now: now, isAlive: alive))
        try record(root, parent: 3001, at: now)
        XCTAssertFalse(model.updateIsIdle(now: now, isAlive: alive)) // The worker still lives while its parent is gone.
    }
    @MainActor func testDeadBusyRecordsDoNotBlockButLiveOrphansRemainUnknown() throws {
        let (root, model) = try fixture(), now = Date()
        XCTAssertTrue(model.updateIsIdle(now: now, isAlive: { _ in false }))
        try record(root, at: now.addingTimeInterval(-30), busy: true)
        XCTAssertTrue(model.updateIsIdle(now: now, isAlive: { _ in false }))
        try FileManager.default.removeItem(at: root.appendingPathComponent("worker.lock"))
        XCTAssertTrue(model.updateIsIdle(now: now, isAlive: { _ in false }))
        XCTAssertFalse(model.updateIsIdle(now: now, isAlive: { $0 == 1001 }))
        try record(root, at: now, busy: false)
        try write(root, "worker.lock", ["token": "dead", "pid": 2001, "parentPid": 0])
        XCTAssertFalse(model.updateIsIdle(now: now, isAlive: { $0 == 1001 }))
    }
    @MainActor func testMalformedUnreadableAndInvalidIdentityRecordsFailClosed() throws {
        let (root, model) = try fixture()
        for name in ["worker.lock", "worker-status.json"] {
            try record(root)
            let file = root.appendingPathComponent(name)
            try Data("{broken".utf8).write(to: file)
            XCTAssertFalse(model.updateIsIdle(isAlive: { _ in false }))
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            XCTAssertFalse(model.updateIsIdle(isAlive: { _ in false }))
            try FileManager.default.removeItem(at: file)
        }
        for pid in [0, -1] {
            try record(root, pid: Int32(pid))
            XCTAssertFalse(model.updateIsIdle(isAlive: { _ in XCTFail("Invalid PID must not be queried"); return false }))
        }
        try record(root)
        try write(root, "worker.lock", ["token": "", "pid": 1001, "parentPid": 0])
        XCTAssertFalse(model.updateIsIdle(isAlive: { _ in false }))
    }
    @MainActor func testInteractionGuardsRemainAndIdleDoesNotRequireCurrentBackendVersion() throws {
        let (root, model) = try fixture(), now = Date()
        let alive: (Int32) -> Bool = { $0 == 1001 }
        let versions: [String?] = [nil, "1.3.3", "1.3.4"]
        for version in versions {
            try record(root, at: now, version: version)
            XCTAssertTrue(model.updateIsIdle(now: now, isAlive: alive))
            XCTAssertEqual(model.workerHealthy(version: "1.3.4", now: now, isAlive: alive), version == "1.3.4")
        }
        model.refreshing = true; XCTAssertFalse(model.updateIsIdle(now: now, isAlive: alive))
        model.refreshing = false; model.interactionActive = true
        XCTAssertFalse(model.updateIsIdle(now: now, isAlive: alive))
        model.interactionActive = false; XCTAssertTrue(model.updateIsIdle(now: now, isAlive: alive))
    }
}
