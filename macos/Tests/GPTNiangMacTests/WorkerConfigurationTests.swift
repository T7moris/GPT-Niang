import XCTest
import Foundation
import Darwin
@testable import GPTNiangMac

final class WorkerConfigurationTests: XCTestCase {
    @MainActor private func fixture(run: (URL, URL, WidgetModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manifest = root.appendingPathComponent("Backend/.codex-plugin/plugin.json")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":"1.3.4"}"#.utf8).write(to: manifest)
        let executable = root.appendingPathComponent("node-fixture")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let previous = getenv("GPT_NIANG_NODE").map { String(cString: $0) }
        setenv("GPT_NIANG_NODE", executable.path, 1)
        let model = WidgetModel(dataDirectory: root, resources: root)
        defer {
            model.stop()
            if let previous { setenv("GPT_NIANG_NODE", previous, 1) } else { unsetenv("GPT_NIANG_NODE") }
            try? FileManager.default.removeItem(at: root)
        }
        try await run(root, executable, model)
    }
    @MainActor private func waitForExit(_ model: WidgetModel) async throws {
        for _ in 0..<200 {
            if !model.workerRunning { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Fixture worker did not exit")
    }
    private func save(_ values: [String: Any], root: URL) throws {
        try JSONSerialization.data(withJSONObject: values).write(to: root.appendingPathComponent("installation.json"), options: .atomic)
    }
    private func config(_ root: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("installation.json"))) as? [String: Any])
    }

    @MainActor func testCustomExecutableWithSpacesAndUnicodeSurvivesStartup() async throws {
        try await fixture { root, _, model in
            let path = "/自定义目录/Custom Codex.app/Contents/Resources/codex"
            try self.save(["codexPath": path], root: root)
            model.tick(); try await self.waitForExit(model)
            XCTAssertEqual(try self.config(root)["codexPath"] as? String, path)
        }
    }

    @MainActor func testCustomPathSurvivesFailedStartRetryAndGuiReopen() async throws {
        try await fixture { root, _, model in
            let path = "/custom/codex", now = ProcessInfo.processInfo.systemUptime
            try self.save(["codexPath": path], root: root)
            model.tick(now: now); try await self.waitForExit(model)
            model.tick(now: now + 5); try await self.waitForExit(model)
            XCTAssertEqual(try self.config(root)["codexPath"] as? String, path)
            model.stop()
            let reopened = WidgetModel(dataDirectory: root, resources: root)
            defer { reopened.stop() }
            reopened.tick(); try await self.waitForExit(reopened)
            XCTAssertEqual(try self.config(root)["codexPath"] as? String, path)
        }
    }

    @MainActor func testMissingOrBlankOrWrongTypeUsesAutomaticDiscoveryDefault() async throws {
        let cases: [[String: Any]] = [[:], ["codexPath": ""], ["codexPath": " \n\t"], ["codexPath": 12], ["codexPath": NSNull()]]
        for values in cases {
            try await fixture { root, _, model in
                try self.save(values, root: root)
                model.tick(); try await self.waitForExit(model)
                XCTAssertEqual(try self.config(root)["codexPath"] as? String, "codex")
            }
        }
    }

    @MainActor func testFirstRunAndMalformedConfigurationKeepPreviousRecoveryBehavior() async throws {
        for malformed in [false, true] {
            try await fixture { root, _, model in
                if malformed { try Data("broken configuration".utf8).write(to: root.appendingPathComponent("installation.json")) }
                model.tick(); try await self.waitForExit(model)
                XCTAssertEqual(try self.config(root)["codexPath"] as? String, "codex")
            }
        }
    }

    @MainActor func testCurrentDataAndNodePathsAreRefreshedWithoutDiscardingCodexPath() async throws {
        try await fixture { root, executable, model in
            let path = "/custom/codex"
            try self.save(["codexPath": path, "dataDir": "/obsolete/data", "nodePath": "/obsolete/node"], root: root)
            model.tick(); try await self.waitForExit(model)
            let values = try self.config(root)
            XCTAssertEqual(values["codexPath"] as? String, path)
            XCTAssertEqual(values["dataDir"] as? String, root.path)
            XCTAssertEqual(values["nodePath"] as? String, executable.path)
        }
    }

    @MainActor func testPreservesLiteralPathInsteadOfTrimmingOrValidatingItAtStartup() async throws {
        try await fixture { root, _, model in
            // Keep the user's spelling even if an update temporarily moves it.
            // The existing Node resolver handles fallbacks on each refresh.
            let path = " /custom directory/codex "
            try self.save(["codexPath": path], root: root)
            model.tick(); try await self.waitForExit(model)
            XCTAssertEqual(try self.config(root)["codexPath"] as? String, path)
        }
    }

    @MainActor func testHealthySharedWorkerReuseDoesNotRewriteConfiguration() async throws {
        try await fixture { root, _, model in
            try self.save(["codexPath": "/custom/codex", "note": "unchanged while shared worker is healthy"], root: root)
            let file = root.appendingPathComponent("installation.json"), before = try Data(contentsOf: file)
            let owner: [String: Any] = ["token": "configuration-fixture", "pid": getpid(), "parentPid": 0]
            var status = owner
            status["version"] = "1.3.4"; status["busy"] = false
            status["at"] = Date().timeIntervalSince1970 * 1000
            for (name, record) in [("worker.lock", owner), ("worker-status.json", status)] {
                try JSONSerialization.data(withJSONObject: record).write(to: root.appendingPathComponent(name), options: .atomic)
            }
            model.tick()
            XCTAssertFalse(model.workerRunning)
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
    }
}
