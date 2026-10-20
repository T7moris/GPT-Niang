import XCTest
@testable import GPTNiangCore

final class AudioPreferencesTests: XCTestCase {
    func testOldDefaultsAndExplicitSilenceAreDistinct() throws {
        XCTAssertEqual(AudioPreferences().mode, .builtin)
        let value = try AudioPreferences.decode(Data(#"{"version":1,"mode":"custom","press":null,"release":null}"#.utf8))
        XCTAssertEqual(value.mode, .custom); XCTAssertNil(value.press); XCTAssertNil(value.release)
    }
    func testIndependentSlotsRoundTrip() throws {
        var value = AudioPreferences(); value.mode = .custom
        value[.release] = AudioEntry(file: String(repeating: "a", count: 32) + ".wav", name: "松开.wav")
        XCTAssertEqual(try AudioPreferences.decode(JSONEncoder().encode(value)), value); XCTAssertNil(value.press)
    }
    func testPathEscapeAndInvalidVersionAreRejected() {
        for json in [#"{"version":2,"mode":"custom"}"#, #"{"version":1,"mode":"custom","press":{"file":"../outside.wav","name":"x"}}"#,
                     #"{"version":1,"mode":"unknown"}"#] {
            XCTAssertThrowsError(try AudioPreferences.decode(Data(json.utf8)))
        }
    }
}
