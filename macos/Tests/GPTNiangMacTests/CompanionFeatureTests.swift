import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import GPTNiangCore
#if !COMPANION_FEATURE_STANDALONE
import XCTest
@testable import GPTNiangMac
#endif

@MainActor
enum CompanionFeatureChecks {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let fm = FileManager.default
        let data = root.appendingPathComponent("data")
        let assets = root.appendingPathComponent("assets")
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        try fixture(assets.appendingPathComponent("gpt-dragon-niang-bust.png"), width: 208, height: 208)
        try Data(#"{"version":1,"quotes":[{"text":"测试语录","weight":1}]}"#.utf8).write(to: assets.appendingPathComponent("quotes.json"))

        // Existing installations retain their old appearance and unknown prefs.
        let prefs = data.appendingPathComponent("preferences.json")
        try Data(#"{"scale":0.8,"followCodex":true,"x":0.2,"futureSetting":"keep"}"#.utf8).write(to: prefs)
        let model = WidgetModel(dataDirectory: data, resources: assets)
        expect(model.scale == 0.8 && model.bubbleScale == 0.8, "legacy size migrates to both scales")
        expect(!model.autoQuoteEnabled && model.autoQuoteIntervalSeconds == 300, "automatic quotes opt in")
        model.scale = 1.4; model.bubbleScale = 0.6; model.autoQuoteEnabled = true; model.autoQuoteIntervalSeconds = 900
        model.completionEnabled = true
        model.savePreferences()
        let restored = WidgetModel(dataDirectory: data, resources: assets)
        expect(restored.scale == 1.4 && restored.bubbleScale == 0.6, "independent sizes persist")
        expect(restored.autoQuoteEnabled && restored.autoQuoteIntervalSeconds == 900, "automatic quote preferences persist")
        expect(restored.completionEnabled, "completion reminder preference survives feature saves")
        let values = try JSONSerialization.jsonObject(with: Data(contentsOf: prefs)) as! [String: Any]
        expect(values["futureSetting"] as? String == "keep" && restored.x == 0.2 && restored.followCodex, "existing preferences preserved")

        for c in [0.6, 0.8, 1, 1.4, 2.5] {
            for b in [0.6, 1, 2.5] {
                let layout = CompanionLayout(characterScale: c, bubbleScale: b)
                let near = CGPoint(x: layout.bubble.minX + 150.5*b, y: layout.bubble.minY + 220*b)
                expect(abs(near.x - layout.character.minX - 8.5*c) < 0.001 &&
                       abs(near.y - layout.character.minY - 78*c) < 0.001, "thought dot remains attached \(c)/\(b)")
                let bounds = CGRect(origin: .zero, size: CGSize(width: layout.size.width - 2*layout.padding, height: layout.size.height - 2*layout.padding)).insetBy(dx: -0.001, dy: -0.001)
                expect(bounds.contains(layout.bubble) && bounds.contains(layout.character), "both components fit \(c)/\(b)")
                let fitted = layout.fitted(in: CGSize(width: 480, height: 300))
                expect(fitted.size.width <= 480.001 && fitted.size.height <= 300.001 &&
                       abs(fitted.characterScale/fitted.bubbleScale - c/b) < 0.001, "small host fits without changing ratio \(c)/\(b)")
                if c == b {
                    expect(abs(layout.size.width - 378*c) < 0.001 && abs(layout.character.minX - 142*c) < 0.001 &&
                           abs(layout.size.height - 378*c) < 0.001, "equal scales preserve original layout")
                }
            }
        }
        expect(CompanionLayout.preferenceScale(.nan) == 1 && CompanionLayout.preferenceScale(99) == 2.5, "invalid scale preferences bounded")

        // A fake monotonic clock tests long intervals without waiting 15 minutes.
        for interval in AutoQuoteSchedule.intervals {
            var schedule = AutoQuoteSchedule()
            var events: [Int] = []
            for tick in 0...interval*2 {
                if schedule.poll(now: Double(tick), enabled: true, interval: interval, eligible: true) { events.append(tick) }
            }
            expect(events == [interval, interval*2], "exact interval \(interval)")
            expect(!schedule.poll(now: Double(interval*2), enabled: true, interval: interval, eligible: true), "no duplicate quote in same tick")
        }
        var schedule = AutoQuoteSchedule()
        for tick in 0..<60 { _ = schedule.poll(now: Double(tick), enabled: true, interval: 60, eligible: true) }
        expect(!schedule.poll(now: 60, enabled: true, interval: 60, eligible: false), "busy/hidden cancels due quote")
        for tick in 61..<121 {
            expect(!schedule.poll(now: Double(tick), enabled: true, interval: 60, eligible: true), "resume waits full interval")
        }
        expect(schedule.poll(now: 121, enabled: true, interval: 60, eligible: true), "resume fires once after full interval")
        expect(!schedule.poll(now: 1000, enabled: true, interval: 60, eligible: true), "wake does not catch up")
        expect(!schedule.poll(now: 999, enabled: true, interval: 60, eligible: true), "clock rollback resets")
        expect(!schedule.poll(now: 1000, enabled: false, interval: 60, eligible: true), "disabled cancels")
        expect(!schedule.poll(now: 1001, enabled: true, interval: 900, eligible: true), "changed settings reset interval")
        expect(AutoQuoteSchedule.validInterval(12) == 300, "invalid interval falls back to five minutes")

        // Gallery copies files, keeps alpha/aspect, validates images, and survives restart.
        let source = root.appendingPathComponent("portrait.png")
        try fixture(source, width: 60, height: 120)
        let original = try Data(contentsOf: source)
        model.importCharacter(at: source)
        let id = model.selectedCharacterID
        expect(id != CharacterRecord.builtin.id && model.characters.count == 2, "import selects new character")
        expect(model.characterImage?.size == CGSize(width: 60, height: 120), "non-square aspect retained")
        expect(try Data(contentsOf: source) == original, "source image unchanged")
        try fm.removeItem(at: source)
        let reloaded = WidgetModel(dataDirectory: data, resources: assets)
        expect(reloaded.selectedCharacterID == id && reloaded.characterImage != nil, "owned image survives deleted original and restart")
        reloaded.removeSelectedCharacter()
        expect(reloaded.characters.count == 1 && reloaded.selectedCharacterID == CharacterRecord.builtin.id && reloaded.canUndoCharacterRemoval, "remove falls back and supports undo")
        let undo = WidgetModel(dataDirectory: data, resources: assets)
        undo.undoCharacterRemoval()
        expect(undo.selectedCharacterID == id && undo.characters.count == 2, "undo survives restart and selects restored image")
        undo.selectCharacter(.builtin); undo.removeSelectedCharacter()
        expect(undo.characters.count == 2, "built-in character cannot be removed")
        for (name, width, height, transparent) in [("invisible.png", 100, 100, true), ("huge.png", 4097, 1, false)] {
            let file = root.appendingPathComponent(name)
            try fixture(file, width: width, height: height, transparent: transparent)
            undo.importCharacter(at: file)
            expect(undo.characters.count == 2 && undo.settingsError != nil, "reject \(name) without changing selection")
        }
        let library = CharacterLibrary(dataDirectory: data)
        let imported = library.characters.first { $0.id == id }!
        let pngSource = CGImageSourceCreateWithURL(library.imageURL(for: imported)! as CFURL, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(pngSource, 0, nil)!
        let pixels = NSBitmapImageRep(cgImage: decoded)
        expect(pixels.colorAt(x: 0, y: 0)!.alphaComponent == 0, "transparent pixels preserved")
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 208, height: 208))
        let pointer = CharacterInteraction.PointerView(frame: container.bounds)
        container.addSubview(pointer); pointer.image = NSImage(cgImage: decoded, size: CGSize(width: 60, height: 120))
        expect(pointer.hitTest(CGPoint(x: 104, y: 104)) === pointer, "visible character remains clickable")
        expect(pointer.hitTest(CGPoint(x: 10, y: 104)) == nil, "aspect-fit empty area passes clicks through")
        expect(pointer.hitTest(CGPoint(x: 60, y: 10)) == nil, "transparent image pixels pass clicks through")
        try fm.removeItem(at: library.imageURL(for: imported)!)
        undo.selectCharacter(imported)
        expect(undo.selectedCharacterID == CharacterRecord.builtin.id && undo.settingsError != nil, "missing selected file reports error")
        let corrupt = root.appendingPathComponent("corrupt/characters")
        try fm.createDirectory(at: corrupt, withIntermediateDirectories: true)
        let invalid = Data(#"{"version":1,"characters":[{"id":"../../outside","name":"bad"}],"removed":[]}"#.utf8)
        try invalid.write(to: corrupt.appendingPathComponent("catalog.json"))
        let invalidLibrary = CharacterLibrary(dataDirectory: corrupt.deletingLastPathComponent())
        expect(invalidLibrary.loadError != nil && invalidLibrary.characters == [.builtin], "invalid catalog cannot escape managed directory")
        try fixture(source, width: 60, height: 120)
        do { try invalidLibrary.importImage(at: source); expect(false, "corrupt catalog must not be overwritten") }
        catch { expect(try Data(contentsOf: corrupt.appendingPathComponent("catalog.json")) == invalid, "corrupt catalog preserved") }

        // Automatic quotes reuse custom quotes, leave quota queries and focus alone.
        let auto = WidgetModel(dataDirectory: root.appendingPathComponent("auto"), resources: assets)
        auto.autoQuoteEnabled = true; auto.autoQuoteIntervalSeconds = 60; auto.presentationVisible = true
        let keyWindow = NSApp.keyWindow
        for tick in 0...60 { auto.tickAutomaticQuotes(now: Double(tick)) }
        expect(auto.message == "测试语录" && auto.bubble, "automatic quote uses existing quote pool")
        expect(!fm.fileExists(atPath: auto.dataDirectory.appendingPathComponent("refresh.flag").path), "automatic quote never queries quota")
        expect(NSApp.keyWindow === keyWindow, "automatic quote does not activate a window")
        auto.characterClick()
        expect(auto.message == nil && auto.bubble, "manual quota immediately takes priority")
        auto.hideBubble(); auto.automaticQuoteBlocked = true
        auto.quoteText = "unsaved draft"
        for tick in 61...150 { auto.tickAutomaticQuotes(now: Double(tick)) }
        expect(!auto.bubble && auto.quoteText == "unsaved draft", "settings block automatic quotes and protect unsaved editor")
        auto.automaticQuoteBlocked = false
        auto.showCompletion()
        let completionMessage = auto.message
        for tick in 151...240 { auto.tickAutomaticQuotes(now: Double(tick)) }
        expect(auto.isCompletionMessage && auto.bubble && auto.message == completionMessage, "automatic quotes cannot replace completion notices")
        auto.hideCompletion()
        for tick in 241...301 { auto.tickAutomaticQuotes(now: Double(tick)) }
        expect(auto.bubble && !auto.isCompletionMessage && auto.message == "测试语录", "automatic quotes resume after a fresh idle interval following completion")
    }

    static func fixture(_ url: URL, width: Int, height: Int, transparent: Bool = false) throws {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !transparent {
            context.setFillColor(CGColor(red: 0.55, green: 0.3, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: width/4, y: height/4, width: max(1, width/2), height: max(1, height/2)))
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw CharacterLibrary.LibraryError.invalidImage }
    }
}

#if COMPANION_FEATURE_STANDALONE
@main struct CompanionFeatureRunner {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var checks = 0, failures = 0
        try CompanionFeatureChecks.run(root: root) { result, message in
            checks += 1
            if !result { failures += 1; print("FAIL: \(message)") }
        }
        print("Companion features: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
#else
final class CompanionFeatureTests: XCTestCase {
    @MainActor func testGalleryIndependentSizingAndAutomaticQuotes() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try CompanionFeatureChecks.run(root: root) { XCTAssertTrue($0, $1) }
    }
}
#endif
