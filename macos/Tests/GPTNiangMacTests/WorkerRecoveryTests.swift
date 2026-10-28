import XCTest
import Foundation
import Darwin
@testable import GPTNiangMac

final class WorkerRecoveryTests: XCTestCase {
    @MainActor private func withFixture(initialStop: String? = nil, initialUptime: TimeInterval? = nil, _ body: @MainActor (URL, WidgetModel, Int32, TimeInterval) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manifest = root.appendingPathComponent("Backend/.codex-plugin/plugin.json")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":"1.3.4"}"#.utf8).write(to: manifest)
        // Recovery tests have no bundled audio. Keep model teardown independent
        // of NSSound loading and the availability of a CI audio device.
        try Data(#"{"version":1,"mode":"custom"}"#.utf8).write(to: root.appendingPathComponent("audio-preferences.json"))
        let executable = root.appendingPathComponent("node-fixture")
        let script = "#!/bin/sh\nprintf x >> \"$(dirname \"$0\")/attempts\"\nprintf '%s' \"$$\" > \"$(dirname \"$0\")/child-pid\"\nexec /bin/sleep 120\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let previous = getenv("GPT_NIANG_NODE").map { String(cString: $0) }
        setenv("GPT_NIANG_NODE", executable.path, 1)
        if let initialStop { try Data(initialStop.utf8).write(to: root.appendingPathComponent("stop.flag")) }
        let model = WidgetModel(dataDirectory: root, resources: root)
        defer {
            model.stop()
            if let previous { setenv("GPT_NIANG_NODE", previous, 1) } else { unsetenv("GPT_NIANG_NODE") }
            try? FileManager.default.removeItem(at: root)
        }
        let now = initialUptime ?? ProcessInfo.processInfo.systemUptime
        model.tick(now: now)
        let pid = try await self.childPID(root)
        try await body(root, model, pid, now)
    }
    private func childPID(_ root: URL, excluding: Int32? = nil) async throws -> Int32 {
        for _ in 0..<200 {
            if let value = try? String(contentsOf: root.appendingPathComponent("child-pid"), encoding: .utf8),
               let pid = Int32(value), pid != excluding { return pid }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "WorkerRecoveryFixture", code: 1)
    }
    @MainActor private func waitForExit(_ model: WidgetModel) async throws {
        for _ in 0..<200 {
            if !model.workerRunning { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Owned fixture worker did not exit after the recovery request")
    }
    private func attempts(_ root: URL) -> Int { (try? Data(contentsOf: root.appendingPathComponent("attempts")).count) ?? 0 }
    private func record(_ root: URL, pid: Int32, parent: Int32 = getpid(), at: Date = Date(),
                        version: String? = "1.3.4", busy: Bool = false) throws {
        let owner: [String: Any] = ["token": "owned-recovery-fixture", "pid": pid, "parentPid": parent]
        var status = owner
        status["at"] = at.timeIntervalSince1970 * 1000; status["version"] = version; status["busy"] = busy
        for (name, value) in [("worker.lock", owner), ("worker-status.json", status)] {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name), options: .atomic)
        }
    }
    @MainActor func testInitialStartupHasThirtySecondsOfContinuousChecks() async throws {
        try await withFixture { root, model, pid, now in
            for step in 1..<30 { model.tick(now: now + Double(step)) }
            XCTAssertTrue(model.workerRunning); XCTAssertEqual(self.attempts(root), 1)
            model.tick(now: now + 30)
            try await self.waitForExit(model)
            XCTAssertFalse(model.workerRunning); XCTAssertFalse(model.updateIdle)
            for step in 31..<35 { model.tick(now: now + Double(step)) }
            XCTAssertEqual(self.attempts(root), 1)
            model.tick(now: now + 35)
            _ = try await self.childPID(root, excluding: pid)
            XCTAssertTrue(model.workerRunning)
            XCTAssertEqual(self.attempts(root), 2)
        }
    }
    @MainActor func testBusyFreshHeartbeatsRemainLiveRegardlessOfQuotaSuccess() async throws {
        try await withFixture { root, model, pid, now in
            try Data(#"{"ok":false,"queryOk":false,"error":"fixture","windows":[]}"#.utf8).write(to: root.appendingPathComponent("status.json"))
            for step in 1...60 {
                try self.record(root, pid: pid, busy: true)
                model.tick(now: now + Double(step))
            }
            XCTAssertTrue(model.workerRunning); XCTAssertEqual(self.attempts(root), 1)
            XCTAssertFalse(model.updateIdle)
        }
    }
    @MainActor func testMomentaryLossResetsAndEachNewOutageReceivesItsOwnGrace() async throws {
        try await withFixture { root, model, pid, now in
            try self.record(root, pid: pid); model.tick(now: now + 1)
            try FileManager.default.removeItem(at: root.appendingPathComponent("worker-status.json"))
            for step in 2...10 { model.tick(now: now + Double(step)) }
            XCTAssertTrue(model.workerRunning); XCTAssertFalse(model.updateIdle)
            try self.record(root, pid: pid); model.tick(now: now + 11)
            try FileManager.default.removeItem(at: root.appendingPathComponent("worker-status.json"))
            for step in 12...21 { model.tick(now: now + Double(step)) }
            XCTAssertTrue(model.workerRunning)
            model.tick(now: now + 22); try await self.waitForExit(model)
        }
    }
    @MainActor func testFractionalUptimeReachesTheRecoveryDeadline() async throws {
        // Crossing 128 seconds makes (now + 12) - (now + 2) round below 10.
        try await withFixture(initialUptime: 117.603463875) { root, model, pid, now in
            try self.record(root, pid: pid); model.tick(now: now + 1)
            try FileManager.default.removeItem(at: root.appendingPathComponent("worker-status.json"))
            for step in 2...11 { model.tick(now: now + Double(step)) }
            XCTAssertTrue(model.workerRunning)
            model.tick(now: now + 12)
            try await self.waitForExit(model)
            XCTAssertFalse(model.workerRunning)
        }
    }
    @MainActor func testFractionalUptimeReachesTheReplacementCooldownDeadline() async throws {
        // The five-second cooldown crosses 256 seconds at this uptime.
        try await withFixture(initialUptime: 224.69351787566157) { root, model, pid, now in
            for step in 1...30 { model.tick(now: now + Double(step)) }
            try await self.waitForExit(model)
            model.tick(now: now + 34)
            XCTAssertEqual(self.attempts(root), 1)
            model.tick(now: now + 35)
            _ = try await self.childPID(root, excluding: pid)
            XCTAssertTrue(model.workerRunning)
            XCTAssertEqual(self.attempts(root), 2)
        }
    }
    @MainActor func testStaleFutureMalformedAndWrongIdentityCannotResetOutage() async throws {
        for scenario in ["stale", "future", "malformed", "identity"] {
            try await withFixture { root, model, pid, now in
                try self.record(root, pid: pid); model.tick(now: now + 1)
                for step in 2...12 {
                    switch scenario {
                    case "stale": try self.record(root, pid: pid, at: Date().addingTimeInterval(-6))
                    case "future": try self.record(root, pid: pid, at: Date().addingTimeInterval(60))
                    case "malformed": try Data("{broken".utf8).write(to: root.appendingPathComponent("worker-status.json"))
                    default: try self.record(root, pid: pid, parent: 0)
                    }
                    model.tick(now: now + Double(step))
                    if step == 11 { XCTAssertTrue(model.workerRunning) }
                }
                try await self.waitForExit(model)
            }
        }
    }
    @MainActor func testVersionMismatchDoesNotTurnALiveOwnedWorkerIntoAStall() async throws {
        try await withFixture { root, model, pid, now in
            for step in 1...45 {
                try self.record(root, pid: pid, version: "1.3.3")
                model.tick(now: now + Double(step))
            }
            XCTAssertTrue(model.workerRunning); XCTAssertEqual(self.attempts(root), 1)
            XCTAssertFalse(model.workerHealthy(version: "1.3.4"))
        }
    }
    @MainActor func testTimerPauseAndSleepDiscardThePreviousOutageDuration() async throws {
        try await withFixture { root, model, pid, now in
            try self.record(root, pid: pid); model.tick(now: now + 1)
            try FileManager.default.removeItem(at: root.appendingPathComponent("worker-status.json"))
            for step in 2...10 { model.tick(now: now + Double(step)) }
            model.tick(now: now + 100)
            for step in 101...109 { model.tick(now: now + Double(step)) }
            XCTAssertTrue(model.workerRunning)
            model.tick(now: now + 110); try await self.waitForExit(model)
        }
    }
    @MainActor func testNonMonotonicAndInvalidCheckTimeCannotTriggerImmediateRecovery() async throws {
        try await withFixture { root, model, pid, now in
            try self.record(root, pid: pid); model.tick(now: now + 1)
            try FileManager.default.removeItem(at: root.appendingPathComponent("worker-status.json"))
            for step in 2...10 { model.tick(now: now + Double(step)) }
            model.tick(now: .nan); model.tick(now: .infinity)
            model.tick(now: now - 10)
            for step in -9 ... -1 { model.tick(now: now + Double(step)) }
            XCTAssertTrue(model.workerRunning)
            model.tick(now: now); try await self.waitForExit(model)
        }
    }
    @MainActor func testOnlyOneAutomaticRecoveryUntilTheReplacementPublishesAHeartbeat() async throws {
        try await withFixture { root, model, pid, now in
            for step in 1...30 { model.tick(now: now + Double(step)) }
            try await self.waitForExit(model)
            XCTAssertFalse(model.updateIdle)
            for step in 31..<35 { model.tick(now: now + Double(step)) }
            XCTAssertEqual(self.attempts(root), 1)
            model.tick(now: now + 35)
            let replacement = try await self.childPID(root, excluding: pid)
            for step in 36...80 { model.tick(now: now + Double(step)) }
            XCTAssertTrue(model.workerRunning); XCTAssertEqual(self.attempts(root), 2)
            try self.record(root, pid: replacement); model.tick(now: now + 81)
            try FileManager.default.removeItem(at: root.appendingPathComponent("worker-status.json"))
            for step in 82...92 { model.tick(now: now + Double(step)) }
            try await self.waitForExit(model)
            XCTAssertEqual(self.attempts(root), 2)
        }
    }
    @MainActor func testNewStopRequestWinsAndPreventsRecoveryRestart() async throws {
        try await withFixture { root, model, pid, now in
            try self.record(root, pid: pid); model.tick(now: now + 1)
            let stop = root.appendingPathComponent("stop.flag"), request = Data("explicit-user-stop".utf8)
            try request.write(to: stop)
            model.tick(now: now + 2); try await self.waitForExit(model)
            for step in 3...60 { model.tick(now: now + Double(step)) }
            XCTAssertFalse(model.workerRunning); XCTAssertEqual(self.attempts(root), 1)
            XCTAssertEqual(try Data(contentsOf: stop), request); XCTAssertFalse(model.updateIdle)
        }
    }
    @MainActor func testNewStopRequestDuringRecoveryAlsoPreventsThePendingRestart() async throws {
        try await withFixture { root, model, _, now in
            for step in 1...30 { model.tick(now: now + Double(step)) }
            try await self.waitForExit(model)
            let stop = root.appendingPathComponent("stop.flag"), request = Data("stop-during-recovery".utf8)
            try request.write(to: stop)
            for step in 31...70 { model.tick(now: now + Double(step)) }
            XCTAssertFalse(model.workerRunning); XCTAssertEqual(self.attempts(root), 1)
            XCTAssertEqual(try Data(contentsOf: stop), request); XCTAssertFalse(model.updateIdle)
        }
    }
    @MainActor func testRecoveryPreservesAnInheritedStopMarkerWithoutBlockingTheNewSession() async throws {
        let inherited = "previous-session-stop"
        try await withFixture(initialStop: inherited) { root, model, pid, now in
            for step in 1...30 { model.tick(now: now + Double(step)) }
            try await self.waitForExit(model)
            for step in 31...35 { model.tick(now: now + Double(step)) }
            _ = try await self.childPID(root, excluding: pid)
            XCTAssertTrue(model.workerRunning); XCTAssertEqual(self.attempts(root), 2)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("stop.flag")), Data(inherited.utf8))
        }
    }
    @MainActor func testAnotherLiveOwnerIsNeverSignalledOrItsMetadataRemoved() async throws {
        try await withFixture { root, model, _, now in
            let other = Process(); other.executableURL = URL(fileURLWithPath: "/bin/sleep"); other.arguments = ["120"]
            try other.run()
            defer { if other.isRunning { other.terminate(); other.waitUntilExit() } }
            try self.record(root, pid: other.processIdentifier, parent: 0)
            let owner = try Data(contentsOf: root.appendingPathComponent("worker.lock"))
            for step in 1...30 { model.tick(now: now + Double(step)) }
            try await self.waitForExit(model)
            XCTAssertTrue(other.isRunning)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("worker.lock")), owner)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("stop.flag").path))
        }
    }
    @MainActor func testHealthySharedReplacementClearsRecoveryWithoutSpawningAContender() async throws {
        try await withFixture { root, model, _, now in
            for step in 1...30 { model.tick(now: now + Double(step)) }
            try await self.waitForExit(model)
            XCTAssertFalse(model.updateIdle)
            try self.record(root, pid: getpid(), parent: 0)
            model.tick(now: now + 31)
            XCTAssertFalse(model.workerRunning); XCTAssertEqual(self.attempts(root), 1)
            XCTAssertTrue(model.workerHealthy(version: "1.3.4")); XCTAssertTrue(model.updateIdle)
        }
    }
}
