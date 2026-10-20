import XCTest
import Foundation
import Darwin
@testable import GPTNiangMac

final class WorkerRetryTests: XCTestCase {
    private let exitScript = "#!/bin/sh\nprintf x >> \"$(dirname \"$0\")/attempts\"\nexit 1\n"

    @MainActor private func withFixture(_ script: String, run: (URL, WidgetModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manifest = root.appendingPathComponent("Backend/.codex-plugin/plugin.json")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":"1.3.4"}"#.utf8).write(to: manifest)
        let executable = root.appendingPathComponent("node-fixture")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let previous = getenv("GPT_NIANG_NODE").map { String(cString: $0) }
        setenv("GPT_NIANG_NODE", executable.path, 1)
        let model = WidgetModel(dataDirectory: root, resources: root)
        defer {
            model.stop()
            if let previous { setenv("GPT_NIANG_NODE", previous, 1) } else { unsetenv("GPT_NIANG_NODE") }
            try? FileManager.default.removeItem(at: root)
        }
        try await run(root, model)
    }
    @MainActor private func waitForExit(_ model: WidgetModel) async throws {
        for _ in 0..<200 {
            if !model.workerRunning { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Fixture worker did not exit")
    }
    private func attempts(_ root: URL) -> Int {
        (try? Data(contentsOf: root.appendingPathComponent("attempts")).count) ?? 0
    }
    private func record(_ root: URL, at: Date = Date(), version: String? = "1.3.4") throws {
        let owner: [String: Any] = ["token": "shared-fixture", "pid": getpid(), "parentPid": 0]
        var status = owner
        status["version"] = version; status["at"] = at.timeIntervalSince1970 * 1000; status["busy"] = true
        for (name, value) in [("worker.lock", owner), ("worker-status.json", status)] {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name), options: .atomic)
        }
    }
    @MainActor func testFailedWorkerRetriesAtFiveSecondsInsteadOfEveryTick() async throws {
        try await withFixture(exitScript) { root, model in
            let now = ProcessInfo.processInfo.systemUptime
            model.tick(now: now); try await self.waitForExit(model)
            XCTAssertEqual(self.attempts(root), 1)
            for delta in [0.0, 1, 2, 4.999] { model.tick(now: now + delta) }
            XCTAssertEqual(self.attempts(root), 1)
            model.tick(now: now + 5); try await self.waitForExit(model)
            XCTAssertEqual(self.attempts(root), 2)
        }
    }
    @MainActor func testProcessLaunchFailureAlsoReservesRetryCooldown() async throws {
        try await withFixture("#!/definitely-missing-niang-test-interpreter\n") { root, model in
            let now = ProcessInfo.processInfo.systemUptime, config = root.appendingPathComponent("installation.json")
            model.tick(now: now)
            XCTAssertFalse(model.workerRunning)
            XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
            try FileManager.default.removeItem(at: config)
            model.tick(now: now + 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
            model.tick(now: now + 5)
            XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
        }
    }
    @MainActor func testMatchingHealthySharedWorkerIsReusedEvenWhileBusy() async throws {
        try await withFixture(exitScript) { root, model in
            let now = ProcessInfo.processInfo.systemUptime
            for delta in [0.0, 1, 5, 10] {
                try self.record(root)
                model.tick(now: now + delta)
            }
            XCTAssertFalse(model.workerRunning) // No child owned by this GUI was needed.
            XCTAssertEqual(self.attempts(root), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("installation.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("worker.log").path))
        }
    }
    @MainActor func testLegacyWrongVersionAndStaleHeartbeatDoNotCountAsReusable() async throws {
        let versions: [String?] = [nil, "1.3.3", "1.3.4"]
        for version in versions {
            try await withFixture(exitScript) { root, model in
                try self.record(root, at: version == "1.3.4" ? Date().addingTimeInterval(-10) : Date(), version: version)
                model.tick(); try await self.waitForExit(model)
                XCTAssertEqual(self.attempts(root), 1)
            }
        }
    }
    @MainActor func testOwnedLiveChildIsPreservedWithoutRestartingDuringCooldown() async throws {
        try await withFixture("#!/bin/sh\nprintf x >> \"$(dirname \"$0\")/attempts\"\nexec /bin/sleep 30\n") { root, model in
            let now = ProcessInfo.processInfo.systemUptime
            model.tick(now: now)
            for _ in 0..<200 {
                if self.attempts(root) == 1 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(model.workerRunning); XCTAssertEqual(self.attempts(root), 1)
            for delta in [1.0, 5, 10] { model.tick(now: now + delta) }
            XCTAssertTrue(model.workerRunning); XCTAssertEqual(self.attempts(root), 1)
            model.stop(); try await self.waitForExit(model)
            XCTAssertFalse(model.workerRunning)
        }
    }
}
