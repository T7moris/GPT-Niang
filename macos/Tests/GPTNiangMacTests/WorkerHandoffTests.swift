import XCTest
import Foundation
import Darwin
@testable import GPTNiangMac

final class WorkerHandoffTests: XCTestCase {
    @MainActor private func withFixture(version: String? = "1.3.3", protocolVersion: Int? = 1,
        parent: Int32 = 0, busy: Bool? = false, at: Date = Date(), initialStop: String? = nil,
        existingPrivate: String? = nil, body: @MainActor (URL, WidgetModel, Process, String) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manifest = root.appendingPathComponent("Backend/.codex-plugin/plugin.json")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":"1.3.4"}"#.utf8).write(to: manifest)
        let executable = root.appendingPathComponent("node-fixture")
        try Data("#!/bin/sh\nprintf x >> \"$(dirname \"$0\")/attempts\"\nexit 1\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let old = Process(); old.executableURL = URL(fileURLWithPath: "/bin/sleep"); old.arguments = ["60"]
        old.standardInput = FileHandle.nullDevice; old.standardOutput = FileHandle.nullDevice; old.standardError = FileHandle.nullDevice
        let previous = getenv("GPT_NIANG_NODE").map { String(cString: $0) }
        setenv("GPT_NIANG_NODE", executable.path, 1)
        var model: WidgetModel?
        defer {
            model?.stop(); self.endOld(old)
            if let previous { setenv("GPT_NIANG_NODE", previous, 1) } else { unsetenv("GPT_NIANG_NODE") }
            try? FileManager.default.removeItem(at: root)
        }
        try old.run()
        let token = UUID().uuidString.lowercased()
        let owner: [String: Any] = ["token": token, "pid": old.processIdentifier, "parentPid": parent]
        var status = owner
        status["at"] = at.timeIntervalSince1970 * 1000; status["busy"] = busy
        status["version"] = version; status["handoffProtocol"] = protocolVersion
        for (name, value) in [("worker.lock", owner), ("worker-status.json", status)] {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name), options: .atomic)
        }
        if let initialStop { try Data(initialStop.utf8).write(to: root.appendingPathComponent("stop.flag")) }
        if let existingPrivate { try Data(existingPrivate.utf8).write(to: self.privateFile(root, token)) }
        let current = WidgetModel(dataDirectory: root, resources: root); model = current
        try await body(root, current, old, token)
    }
    private func privateFile(_ root: URL, _ token: String) -> URL {
        root.appendingPathComponent("worker-handoff-" + token + ".flag")
    }
    @MainActor private func endOld(_ process: Process) {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
    }
    private func attempts(_ root: URL) -> Int { (try? Data(contentsOf: root.appendingPathComponent("attempts")).count) ?? 0 }
    @MainActor private func waitForExit(_ model: WidgetModel) async throws {
        for _ in 0..<200 {
            if !model.workerRunning { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Fixture worker did not exit")
    }

    @MainActor func testModernHandoffTargetsOnlyOldHeadlessOwnerAndBlocksUpdateWhileWaiting() async throws {
        try await withFixture { root, model, old, token in
            let now = ProcessInfo.processInfo.systemUptime
            model.tick(now: now)
            let request = try Data(contentsOf: self.privateFile(root, token))
            XCTAssertTrue(String(decoding: request, as: UTF8.self).hasPrefix("worker-handoff:" + token + ":"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("stop.flag").path))
            XCTAssertFalse(model.updateIdle); XCTAssertFalse(model.workerHealthy(version: "1.3.4"))
            model.tick(now: now + 100)
            XCTAssertTrue(old.isRunning); XCTAssertEqual(self.attempts(root), 0)
            XCTAssertEqual(try Data(contentsOf: self.privateFile(root, token)), request)
            model.stop(); XCTAssertTrue(old.isRunning) // Only the test owns this Process object.
        }
    }
    @MainActor func testModernHandoffStartsReplacementAfterOldOwnerActuallyExits() async throws {
        try await withFixture { root, model, old, token in
            let now = ProcessInfo.processInfo.systemUptime
            model.tick(now: now); self.endOld(old)
            model.tick(now: now + 4); XCTAssertEqual(self.attempts(root), 0)
            model.tick(now: now + 5); try await self.waitForExit(model)
            XCTAssertEqual(self.attempts(root), 1); XCTAssertTrue(model.updateIdle)
            // The fixture does not consume requests; GUI never deletes this private request.
            XCTAssertTrue(FileManager.default.fileExists(atPath: self.privateFile(root, token).path))
        }
    }
    @MainActor func testLegacyHandoffPreservesItsMarkerAndResumesWithoutBeingStoppedByIt() async throws {
        try await withFixture(version: nil, protocolVersion: nil) { root, model, old, token in
            let now = ProcessInfo.processInfo.systemUptime, stop = root.appendingPathComponent("stop.flag")
            model.tick(now: now)
            let request = try Data(contentsOf: stop)
            XCTAssertTrue(String(decoding: request, as: UTF8.self).hasPrefix("worker-handoff:" + token + ":"))
            XCTAssertFalse(model.updateIdle); self.endOld(old)
            model.tick(now: now + 5); try await self.waitForExit(model)
            XCTAssertEqual(self.attempts(root), 1); XCTAssertEqual(try Data(contentsOf: stop), request)
            XCTAssertTrue(model.updateIdle)
        }
    }
    @MainActor func testLegacyOwnerWithExistingGeneralStopRequestWaitsWithoutOverwriting() async throws {
        try await withFixture(version: nil, protocolVersion: nil, initialStop: "another-caller-stop") { root, model, old, token in
            let now = ProcessInfo.processInfo.systemUptime
            for delta in [0.0, 5, 10] { model.tick(now: now + delta) }
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("stop.flag"), encoding: .utf8), "another-caller-stop")
            XCTAssertFalse(FileManager.default.fileExists(atPath: self.privateFile(root, token).path))
            XCTAssertEqual(self.attempts(root), 0); XCTAssertTrue(old.isRunning)
        }
    }
    @MainActor func testLiveGUIBusyStaleUnknownAndCurrentVersionDoNotReceiveHandoff() async throws {
        let cases: [(String?, Int32, Bool?, Date)] = [("1.3.3", getpid(), false, Date()),
            ("1.3.3", 0, true, Date()), ("1.3.3", 0, nil, Date()),
            ("1.3.3", 0, false, Date().addingTimeInterval(-10)), ("1.3.4", 0, false, Date()),
            ("1.3.5", 0, false, Date()), ("unknown-version", 0, false, Date()), (nil, 0, false, Date())]
        for (version, parent, busy, at) in cases {
            try await withFixture(version: version, parent: parent, busy: busy, at: at) { root, model, old, token in
                model.tick()
                XCTAssertFalse(FileManager.default.fileExists(atPath: self.privateFile(root, token).path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("stop.flag").path))
                XCTAssertEqual(self.attempts(root), 0); model.stop(); XCTAssertTrue(old.isRunning)
            }
        }
        try await withFixture(protocolVersion: 2) { root, model, old, token in
            model.tick()
            XCTAssertFalse(FileManager.default.fileExists(atPath: self.privateFile(root, token).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("stop.flag").path))
            XCTAssertEqual(self.attempts(root), 0); model.stop(); XCTAssertTrue(old.isRunning)
        }
    }
    @MainActor func testForeignGeneralStopDuringModernHandoffPreventsAutomaticRestartAndUpdate() async throws {
        try await withFixture { root, model, old, _ in
            let now = ProcessInfo.processInfo.systemUptime, stop = root.appendingPathComponent("stop.flag")
            model.tick(now: now)
            let foreign = Data("external-stop".utf8); try foreign.write(to: stop)
            model.tick(now: now + 1); XCTAssertTrue(old.isRunning); XCTAssertFalse(model.updateIdle)
            self.endOld(old); model.tick(now: now + 10)
            XCTAssertEqual(self.attempts(root), 0); XCTAssertEqual(try Data(contentsOf: stop), foreign)
            XCTAssertFalse(model.updateIdle)
        }
    }
    @MainActor func testReplacedLegacyStopRequestIsNeverAdoptedAsOurCompletedHandoff() async throws {
        try await withFixture(version: nil, protocolVersion: nil) { root, model, old, _ in
            let now = ProcessInfo.processInfo.systemUptime, stop = root.appendingPathComponent("stop.flag")
            model.tick(now: now)
            let foreign = Data("new-caller-stop".utf8); try foreign.write(to: stop)
            model.tick(now: now + 1); self.endOld(old); model.tick(now: now + 10)
            XCTAssertEqual(self.attempts(root), 0); XCTAssertEqual(try Data(contentsOf: stop), foreign)
            XCTAssertFalse(model.updateIdle)
        }
    }
    @MainActor func testExistingPrivateRequestIsSharedAndOldGeneralMarkerIsPreserved() async throws {
        try await withFixture(initialStop: "old-general-stop", existingPrivate: "another-private-request") { root, model, old, token in
            let now = ProcessInfo.processInfo.systemUptime
            model.tick(now: now); XCTAssertFalse(model.updateIdle)
            XCTAssertEqual(try String(contentsOf: self.privateFile(root, token), encoding: .utf8), "another-private-request")
            self.endOld(old); model.tick(now: now + 5); try await self.waitForExit(model)
            XCTAssertEqual(self.attempts(root), 1)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("stop.flag"), encoding: .utf8), "old-general-stop")
            XCTAssertEqual(try String(contentsOf: self.privateFile(root, token), encoding: .utf8), "another-private-request")
        }
    }
    @MainActor func testOwnershipReleaseCanCompleteBeforeProcessReapingButCorruptionCannot() async throws {
        try await withFixture { root, model, old, _ in
            let now = ProcessInfo.processInfo.systemUptime, owner = root.appendingPathComponent("worker.lock")
            model.tick(now: now)
            try Data("{broken".utf8).write(to: owner)
            model.tick(now: now + 5)
            XCTAssertEqual(self.attempts(root), 0); XCTAssertFalse(model.updateIdle)
            // Simulate metadata released by the exit handler before process reaping.
            try FileManager.default.removeItem(at: owner)
            try FileManager.default.removeItem(at: root.appendingPathComponent("worker-status.json"))
            model.tick(now: now + 6); try await self.waitForExit(model)
            XCTAssertEqual(self.attempts(root), 1); XCTAssertTrue(old.isRunning)
            // The real backend still acquires the unchanged exclusive kernel lock before publishing.
        }
    }
}
