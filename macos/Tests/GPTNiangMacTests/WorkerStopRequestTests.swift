import XCTest
import Foundation
import Darwin
@testable import GPTNiangMac

final class WorkerStopRequestTests: XCTestCase {
    @MainActor private func withFixture(initial: Data? = nil, alive: Bool = false, run: (URL, WidgetModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manifest = root.appendingPathComponent("Backend/.codex-plugin/plugin.json")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":"1.3.4"}"#.utf8).write(to: manifest)
        if let initial { try initial.write(to: root.appendingPathComponent("stop.flag")) }
        let executable = root.appendingPathComponent("node-fixture")
        let ending = alive ? "exec /bin/sleep 30\n" : "exit 1\n"
        try Data(("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$(dirname \"$0\")/arguments\"\nprintf x >> \"$(dirname \"$0\")/attempts\"\n" + ending).utf8).write(to: executable)
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
    private func attempts(_ root: URL) -> Int { (try? Data(contentsOf: root.appendingPathComponent("attempts")).count) ?? 0 }

    @MainActor func testInitializationPreservesExistingRequestAndAllowsExplicitReopen() async throws {
        let token = Data("previous-stop".utf8)
        try await withFixture(initial: token) { root, model in
            let stop = root.appendingPathComponent("stop.flag")
            XCTAssertEqual(try Data(contentsOf: stop), token)
            let before = try FileManager.default.attributesOfItem(atPath: stop.path)[.modificationDate] as? Date
            model.tick(); try await self.waitForExit(model)
            XCTAssertEqual(self.attempts(root), 1)
            let arguments = try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8)
            XCTAssertEqual(arguments.split(separator: "\n").last, "--inherit-stop")
            XCTAssertEqual(try Data(contentsOf: stop), token)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: stop.path)[.modificationDate] as? Date, before)
        }
    }
    @MainActor func testNewRequestBeforeFirstStartPreventsLaunching() async throws {
        try await withFixture { root, model in
            let stop = root.appendingPathComponent("stop.flag")
            try Data("new-stop".utf8).write(to: stop)
            let now = ProcessInfo.processInfo.systemUptime
            for delta in [0.0, 5, 10] { model.tick(now: now + delta) }
            XCTAssertFalse(model.workerRunning); XCTAssertEqual(self.attempts(root), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("installation.json").path))
            XCTAssertEqual(try Data(contentsOf: stop), Data("new-stop".utf8))
        }
    }
    @MainActor func testNewStopPreventsAutomaticRestartButReopeningCanResume() async throws {
        try await withFixture { root, model in
            let now = ProcessInfo.processInfo.systemUptime, stop = root.appendingPathComponent("stop.flag")
            model.tick(now: now); try await self.waitForExit(model)
            XCTAssertEqual(self.attempts(root), 1)
            let token = Data("stop-during-session".utf8); try token.write(to: stop)
            for delta in [5.0, 10, 20] { model.tick(now: now + delta) }
            XCTAssertEqual(self.attempts(root), 1)
            let reopened = WidgetModel(dataDirectory: root, resources: root)
            defer { reopened.stop() }
            reopened.tick(now: now + 21); try await self.waitForExit(reopened)
            XCTAssertEqual(self.attempts(root), 2); XCTAssertEqual(try Data(contentsOf: stop), token)
        }
    }
    @MainActor func testSameContentsWithNewTimestampIsStillANewRequest() async throws {
        let token = Data("same-stop".utf8)
        try await withFixture(initial: token) { root, model in
            let stop = root.appendingPathComponent("stop.flag")
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: stop.path)
            model.tick()
            XCTAssertFalse(model.workerRunning); XCTAssertEqual(self.attempts(root), 0)
            XCTAssertEqual(try Data(contentsOf: stop), token)
        }
    }
    @MainActor func testRequestArrivingDuringStartupStopsOwnedChildEvenIfChildInheritedIt() async throws {
        try await withFixture(alive: true) { root, model in
            let now = ProcessInfo.processInfo.systemUptime
            model.tick(now: now)
            for _ in 0..<200 {
                if self.attempts(root) == 1 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(model.workerRunning); XCTAssertEqual(self.attempts(root), 1)
            let token = Data("stop-during-child-start".utf8)
            try token.write(to: root.appendingPathComponent("stop.flag"))
            // The child fixture does not observe the flag; the GUI must cover this startup race.
            model.tick(now: now + 1); try await self.waitForExit(model)
            XCTAssertFalse(model.workerRunning)
            model.tick(now: now + 20); XCTAssertEqual(self.attempts(root), 1)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("stop.flag")), token)
        }
    }
    @MainActor func testEmptyAndOversizedFilesRemainIgnoredLikeNodeRequestReader() async throws {
        for contents in [Data(), Data(repeating: 65, count: 4097)] {
            try await withFixture(initial: contents) { root, model in
                model.tick(); try await self.waitForExit(model)
                XCTAssertEqual(self.attempts(root), 1)
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("stop.flag")), contents)
            }
        }
    }
}
