import XCTest
@testable import GPTNiangCore

final class HostLinkTests: XCTestCase {
    func testApplicationLifecycleAndManualPetExit() {
        var state = HostLinkState()
        XCTAssertEqual(state.observe(enabled: true, hostProcesses: []), .none)
        XCTAssertEqual(state.observe(enabled: true, hostProcesses: [1]), .launch)
        XCTAssertEqual(state.observe(enabled: true, hostProcesses: [1]), .none)
        XCTAssertEqual(state.observe(enabled: true, hostProcesses: []), .quit)
        XCTAssertEqual(state.observe(enabled: true, hostProcesses: []), .none)
        XCTAssertEqual(state.observe(enabled: true, hostProcesses: [1]), .launch)
        XCTAssertEqual(state.observe(enabled: false, hostProcesses: []), .none)
    }
    func testOldPreferencesRemainOptIn() throws {
        let prefs = try JSONDecoder().decode(HostLinkPreferences.self, from: Data("{}".utf8))
        XCTAssertFalse(prefs.enabled)
        XCTAssertEqual(prefs.bundleIdentifier, "com.openai.codex")
    }
}
