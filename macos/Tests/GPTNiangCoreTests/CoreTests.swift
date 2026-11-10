import XCTest
@testable import GPTNiangCore

final class CoreTests: XCTestCase {
    func testDecodeActualWorkerSnapshotWithMissingResetAndAbsentFiveHourWindow() throws {
        let data = Data(#"{"ok":true,"queryOk":true,"observedAt":1000000,"windows":[{"minutes":10080,"used":86,"remaining":14,"resetsAt":null}],"accountKey":"hash"}"#.utf8)
        let result = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows.first?.remaining, 14)
        XCTAssertEqual(result.windows.first?.resetText(at: Date()), "未提供重置時間")
    }
    func testExpiredQuotaNeverInventsReplenishment() {
        let window = QuotaWindow(minutes: 300, remaining: 0, resetsAt: 100)
        XCTAssertTrue(window.expired(at: Date(timeIntervalSince1970: 101)))
        XCTAssertEqual(window.remaining, 0)
        XCTAssertEqual(window.resetText(at: Date(timeIntervalSince1970: 101)), "等待更新後的額度")
    }
    func testDirectQuotaMarksUnverifiedAccountAndKeepsLegacySnapshotsCompatible() throws {
        let direct = try JSONDecoder().decode(UsageSnapshot.self, from: Data(#"{"ok":true,"queryOk":true,"accountVerified":false,"windows":[]}"#.utf8))
        let legacy = try JSONDecoder().decode(UsageSnapshot.self, from: Data(#"{"ok":true,"queryOk":true,"windows":[]}"#.utf8))
        XCTAssertEqual(direct.accountVerified, false)
        XCTAssertNil(legacy.accountVerified)
        XCTAssertEqual(InterfaceLanguage.simplified.text("帳戶待確認"), "账户待确认")
        XCTAssertEqual(InterfaceLanguage.traditional.text("帳戶待確認"), "帳戶待確認")
    }
    func testPlanMetadataAndArbitraryQuotaWindowTitles() throws {
        let data = Data(#"{"ok":true,"queryOk":true,"plan":"go","planLabel":"Go","windows":[{"minutes":43200,"remaining":88,"resetsAt":null}]}"#.utf8)
        let result = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        XCTAssertEqual(result.plan, "go")
        XCTAssertEqual(result.planLabel, "Go")
        XCTAssertEqual(result.windows.first?.title, "30 天")
        for (minutes, title) in [(300, "5 小時"), (10080, "每週"), (60, "1 小時"), (1440, "1 天"), (75, "75 分鐘")] {
            XCTAssertEqual(QuotaWindow(minutes: minutes, remaining: 100).title, title)
        }
        let legacy = try JSONDecoder().decode(UsageSnapshot.self, from: Data(#"{"ok":true,"windows":[]}"#.utf8))
        XCTAssertNil(legacy.plan)
    }
    func testAccountFingerprintAndVerificationMetadataCoexist() throws {
        let data = Data(#"{"ok":true,"queryOk":true,"windows":[],"accountKey":"fingerprint","accountVerified":true}"#.utf8)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        XCTAssertEqual(decoded.accountKey, "fingerprint")
        XCTAssertEqual(decoded.accountVerified, true)
        let constructed = UsageSnapshot(accountKey: "fingerprint", accountVerified: true)
        XCTAssertEqual(constructed.accountKey, decoded.accountKey)
        XCTAssertEqual(constructed.accountVerified, decoded.accountVerified)
    }
    // PR #9 cases retain the current exact-duration titles, including Go's 30 days.
    func testCalendarLikeAndFutureWindowTitlesKeepTheirActualDuration() {
        for (minutes, title) in [(40320, "28 天"), (43200, "30 天"), (43800, "730 小時"), (44640, "31 天"), (21600, "15 天"), (90, "90 分鐘")] {
            XCTAssertEqual(QuotaWindow(minutes: minutes, remaining: 100).title, title)
        }
    }
    func testLocalTimeZoneAndShortCountdown() {
        let window = QuotaWindow(minutes: 10080, remaining: 75, resetsAt: 172800)
        XCTAssertEqual(window.resetText(at: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 28800)!), "1/3 08:00 重置")
        XCTAssertEqual(window.resetText(at: Date(timeIntervalSince1970: 169199)), "1 小時 1 分鐘後重置")
    }
    func testFailedSameAccountAndOldSnapshotsStayVisiblyStale() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(UsageSnapshot(ok: true, queryOk: false, observedAt: 1000000).stale(at: now))
        XCTAssertTrue(UsageSnapshot(ok: true, queryOk: true, observedAt: 819999).stale(at: now))
        XCTAssertFalse(UsageSnapshot(ok: true, queryOk: true, observedAt: 1000000).stale(at: now))
    }
    func testQuoteValidationBOMAndNoImmediateRepeat() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(#"{"quotes":["你好",{"text":"再試一次","weight":3},{"text":"","weight":1},{"text":"無效","weight":0}]}"#.utf8))
        let quotes = try QuoteFile.decode(data)
        XCTAssertEqual(quotes.count, 2)
        XCTAssertEqual(QuoteFile.choose(quotes, excluding: "你好", draw: 0), "再試一次")
        XCTAssertEqual(QuoteFile.choose([Quote(text: "唯一")], excluding: "唯一"), "唯一")
    }
    func testQuartzConversionForMainAndSecondaryDisplays() {
        XCTAssertEqual(WidgetPlacement.appKitRect(quartz: CGRect(x: 0, y: 50, width: 100, height: 200), mainDisplayHeight: 900).minY, 650)
        XCTAssertEqual(WidgetPlacement.appKitRect(quartz: CGRect(x: -1200, y: -600, width: 900, height: 400), mainDisplayHeight: 900).minY, 1100)
    }
    func testPanelClampedInsideSmallWindowsAndOffscreenHosts() {
        let screen = CGRect(x: -1000, y: 0, width: 1000, height: 700)
        for host in [CGRect(x: -1200, y: -200, width: 900, height: 1000), CGRect(x: -600, y: 100, width: 200, height: 200)] {
            let frame = WidgetPlacement.frame(host: host, visibleScreen: screen, size: CGSize(width: 320, height: 330), x: 9, y: -5)
            XCTAssertTrue(screen.contains(frame))
            XCTAssertTrue(host.intersection(screen).contains(frame))
        }
    }
    func testAppearanceModesAndTokenPaletteKeepRandomDrawSeparateFromTextChoice() {
        XCTAssertEqual(Appearance.scope(mode: .mixed, quote: "hello", special: [], fullChance: 0.5, textChance: 3, draw: 0.001), .full)
        XCTAssertEqual(Appearance.scope(mode: .mixed, quote: "hello", special: [], fullChance: 0.5, textChance: 3, draw: 0.01), .text)
        XCTAssertEqual(Appearance.scope(mode: .mixed, quote: nil, special: [], fullChance: 100, textChance: 0, draw: 0), .none)
        XCTAssertEqual(Appearance.scope(mode: .special, quote: "Token", special: ["Token"], fullChance: 0, textChance: 0, draw: 1), .full)
        XCTAssertEqual(Appearance.palette(for: "額度"), Appearance.palette(for: "token"))
        XCTAssertEqual(Appearance.palette(for: "Claude 和 GPT"), Appearance.palette(for: "", rainbow: true))
    }
    func testDraggingUsesTheSameClippedAreaAsRestoredPlacement() {
        let screen = CGRect(x: 0, y: 40, width: 1000, height: 700)
        let host = CGRect(x: -300, y: 0, width: 1000, height: 800)
        let area = WidgetPlacement.usableArea(host: host, visibleScreen: screen)
        let size = CGSize(width: 378, height: 378)
        let frame = WidgetPlacement.frame(host: host, visibleScreen: screen, size: size, x: 0.25, y: 0.75)
        let x = (frame.minX - area.minX - 12) / (area.width - size.width - 24)
        let y = (frame.minY - area.minY - 12) / (area.height - size.height - 24)
        XCTAssertEqual(WidgetPlacement.frame(host: area, visibleScreen: area, size: size, x: x, y: y), frame)
    }
}
