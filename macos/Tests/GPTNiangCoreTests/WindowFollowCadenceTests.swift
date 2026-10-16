import XCTest
@testable import GPTNiangCore

final class WindowFollowCadenceTests: XCTestCase {
    func testPanelBehindHostIsRecoveredWithoutRaisingAboveOtherApps() {
        XCTAssertTrue(WindowFollowOrdering.needsOrdering(frontToBack: [90, 10, 20], host: 10, panel: 20))
        XCTAssertFalse(WindowFollowOrdering.needsOrdering(frontToBack: [90, 20, 10], host: 10, panel: 20))
        XCTAssertTrue(WindowFollowOrdering.needsOrdering(frontToBack: [90, 10], host: 10, panel: 20))
        XCTAssertFalse(WindowFollowOrdering.needsOrdering(frontToBack: [90, 20], host: 10, panel: 20))
    }

    func testFastPositionTicksDoNotRepeatFullDiscovery() {
        var cadence = WindowFollowCadence()
        XCTAssertTrue(cadence.discover(now: 0))
        for tick in 1..<15 { XCTAssertFalse(cadence.discover(now: Double(tick) / 60)) }
        XCTAssertTrue(cadence.discover(now: 0.25))
        XCTAssertTrue(cadence.discover(now: 0.26, force: true))
        XCTAssertFalse(cadence.discover(now: 0.27))
    }

    func testVisibilityChangesWriteImmediatelyBetweenHeartbeats() {
        var cadence = WindowFollowCadence()
        XCTAssertTrue(cadence.presence(now: 0, visible: true))
        XCTAssertFalse(cadence.presence(now: 0.5, visible: true))
        XCTAssertTrue(cadence.presence(now: 0.6, visible: false))
        XCTAssertTrue(cadence.presence(now: 0.7, visible: true))
        XCTAssertFalse(cadence.presence(now: 1.6, visible: true))
        XCTAssertTrue(cadence.presence(now: 1.7, visible: true))
    }

    func testDiagnosticsHaveAnIndependentLimit() {
        var cadence = WindowFollowCadence()
        XCTAssertTrue(cadence.diagnostics(now: 0))
        XCTAssertTrue(cadence.presence(now: 0, visible: true))
        XCTAssertFalse(cadence.diagnostics(now: 0.1))
        XCTAssertTrue(cadence.diagnostics(now: 0.25))
        XCTAssertFalse(cadence.presence(now: 0.25, visible: true))
    }
    func testMinimizedOrClosedHostDoesNotReceiveTransientMetadataGrace() {
        XCTAssertFalse(WindowFollowVisibility.keepDuringMissingHost(appHidden: false, confirmedMissing: true, missingFor: 0))
        XCTAssertFalse(WindowFollowVisibility.keepDuringMissingHost(appHidden: true, confirmedMissing: false, missingFor: 0))
        XCTAssertTrue(WindowFollowVisibility.keepDuringMissingHost(appHidden: false, confirmedMissing: false, missingFor: 0))
        XCTAssertTrue(WindowFollowVisibility.keepDuringMissingHost(appHidden: false, confirmedMissing: false, missingFor: 0.74))
        XCTAssertFalse(WindowFollowVisibility.keepDuringMissingHost(appHidden: false, confirmedMissing: false, missingFor: 0.75))
        XCTAssertFalse(WindowFollowVisibility.keepDuringMissingHost(appHidden: false, confirmedMissing: false, missingFor: -1))
    }

}
