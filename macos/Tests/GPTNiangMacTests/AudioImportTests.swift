import XCTest
import AppKit
import GPTNiangCore
@testable import GPTNiangMac

@MainActor
final class AudioImportTests: XCTestCase {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gpt-audio-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bytes = Data()
        func text(_ value: String) { bytes.append(contentsOf: value.utf8) }
        func word(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) } }
        func dword(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) } }
        text("RIFF"); dword(196); text("WAVEfmt "); dword(16); word(1); word(1); dword(8000); dword(16000); word(2); word(16)
        text("data"); dword(160); bytes.append(Data(repeating: 0, count: 160))
        try bytes.write(to: directory.appendingPathComponent("press.wav")); try bytes.write(to: directory.appendingPathComponent("release.wav"))
        return directory
    }
    private func model(_ directory: URL) -> WidgetAudio {
        WidgetAudio(data: directory, resources: directory, node: { nil }, enabled: { false }, volume: { 0.37 }, text: { $0 })
    }
    func testExplicitSilencePersistsAcrossRestart() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let audio = model(directory); audio.perform("clear", slot: .press)
        let restarted = model(directory)
        XCTAssertEqual(restarted.preferences.mode, .custom); XCTAssertNil(restarted.preferences.press); XCTAssertNil(restarted.preferences.release)
        restarted.play("press"); restarted.play("release"); restarted.updateVolume(); restarted.stop()
    }
    func testOneMissingClipDoesNotDiscardOtherSlot() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let sounds = directory.appendingPathComponent("sounds"); try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        var prefs = AudioPreferences(); prefs.mode = .custom
        prefs.release = AudioEntry(file: String(repeating: "a", count: 32) + ".wav", name: "release.wav")
        prefs.press = AudioEntry(file: String(repeating: "b", count: 32) + ".wav", name: "missing.wav")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("release.wav"), to: sounds.appendingPathComponent(prefs.release!.file))
        try JSONEncoder().encode(prefs).write(to: directory.appendingPathComponent("audio-preferences.json"))
        let audio = model(directory)
        XCTAssertNotNil(audio.errors[.press]); XCTAssertNil(audio.errors[.release]); XCTAssertEqual(audio.preferences.release, prefs.release)
    }
}
