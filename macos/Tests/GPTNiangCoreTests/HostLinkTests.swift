import XCTest
@testable import GPTNiangCore

final class HostLinkTests: XCTestCase {
    func testBundledHelperResolvesItsOwnInstallation() {
        XCTAssertEqual(HostLinkInstallation.applicationURL(executablePath:
            "/Applications/GPTNiangMac.app/Contents/Helpers/GPTNiangHostLink")?.path,
            "/Applications/GPTNiangMac.app")
        XCTAssertEqual(HostLinkInstallation.applicationURL(executablePath:
            "/Users/example/Other Apps/GPT 娘.app/Contents/Helpers/GPTNiangHostLink")?.path,
            "/Users/example/Other Apps/GPT 娘.app")
    }

    func testRelativeLaunchdArgumentDoesNotResolveToTheStartupDisk() {
        XCTAssertNil(HostLinkInstallation.applicationURL(executablePath: "Contents/Helpers/GPTNiangHostLink"))
        XCTAssertNil(HostLinkInstallation.applicationURL(executablePath: "GPTNiangHostLink"))
        XCTAssertNil(HostLinkInstallation.applicationURL(executablePath: ""))
        XCTAssertNil(HostLinkInstallation.applicationURL(executablePath: "/"))
    }

    func testUnbundledOrMisplacedHelperCannotLaunchADirectory() {
        XCTAssertNil(HostLinkInstallation.applicationURL(executablePath: "/tmp/.build/debug/GPTNiangHostLink"))
        XCTAssertNil(HostLinkInstallation.applicationURL(executablePath: "/Applications/GPTNiangMac/Contents/Helpers/GPTNiangHostLink"))
        XCTAssertNil(HostLinkInstallation.applicationURL(executablePath: "/Applications/GPTNiangMac.app/Contents/MacOS/GPTNiangHostLink"))
        XCTAssertNil(HostLinkInstallation.applicationURL(executablePath: "/Applications/GPTNiangMac.app/Contents/Helpers/OtherHelper"))
    }

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
