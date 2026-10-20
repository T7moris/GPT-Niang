import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GPTNiangCore

@MainActor
final class WidgetAudio: ObservableObject {
    @Published private(set) var preferences = AudioPreferences()
    @Published private(set) var errors: [AudioSlot: String] = [:]
    @Published private(set) var busy = false
    private let data: URL
    private let resources: URL
    private let node: () -> URL?
    private let enabled: () -> Bool
    private let volume: () -> Double
    let text: (String) -> String
    private var players: [AudioSlot: NSSound] = [:]
    private var preview: NSSound?
    private var pressing = false
    private var pressedAt = Date.distantPast
    private var releaseWork: DispatchWorkItem?
    private var playbackGeneration = 0
    private var config: URL { data.appendingPathComponent("audio-preferences.json") }

    init(data: URL, resources: URL, node: @escaping () -> URL?, enabled: @escaping () -> Bool,
         volume: @escaping () -> Double, text: @escaping (String) -> String) {
        self.data = data; self.resources = resources; self.node = node
        self.enabled = enabled; self.volume = volume; self.text = text
        if FileManager.default.fileExists(atPath: config.path) {
            do { preferences = try AudioPreferences.decode(Data(contentsOf: config)) }
            catch { preferences.mode = .custom; errors[.press] = text("音效设置无法读取，请重新选择音效。") }
        }
        if let loaded = try? prepare(preferences) { players = loaded.0; errors.merge(loaded.1) { _, next in next } }
    }
    private func source(_ slot: AudioSlot, custom: Bool = false, prefs: AudioPreferences? = nil) -> URL? {
        let current = prefs ?? preferences
        if !custom && current.mode == .builtin { return resources.appendingPathComponent(slot.rawValue + ".wav") }
        guard let entry = current[slot] else { return nil }
        return data.appendingPathComponent("sounds").appendingPathComponent(entry.file)
    }
    private func prepare(_ prefs: AudioPreferences) throws -> ([AudioSlot: NSSound], [AudioSlot: String]) {
        var loaded: [AudioSlot: NSSound] = [:], failed: [AudioSlot: String] = [:]
        for slot in AudioSlot.allCases {
            guard let file = source(slot, prefs: prefs) else { continue }
            if let sound = NSSound(contentsOf: file, byReference: false), sound.duration.isFinite,
               sound.duration > 0, sound.duration <= 5 { loaded[slot] = sound }
            else if prefs.mode == .builtin { throw CocoaError(.fileReadCorruptFile) }
            else { failed[slot] = text("文件不可用，请重新选择。") }
        }
        return (loaded, failed)
    }
    private func apply(_ next: AudioPreferences, required: AudioSlot? = nil) throws {
        let loaded = try prepare(next)
        if let required, loaded.0[required] == nil { throw CocoaError(.fileReadCorruptFile) }
        let bytes = try JSONEncoder().encode(next)
        try bytes.write(to: config, options: .atomic)
        stop(); preferences = next; players = loaded.0; errors = loaded.1
    }
    func stop() {
        playbackGeneration += 1
        releaseWork?.cancel(); releaseWork = nil; pressing = false
        for sound in players.values { sound.stop() }; preview?.stop(); preview = nil
    }
    func updateVolume() {
        if !enabled() || volume() <= 0 { stop(); return }
        for sound in players.values { sound.volume = Float(volume()) }; preview?.volume = Float(volume())
    }
    func play(_ name: String) {
        guard let slot = AudioSlot(rawValue: name) else { return }
        if slot == .press {
            stop(); guard enabled(), volume() > 0, !players.isEmpty else { return }
            pressing = true; pressedAt = Date(); players[.press]?.volume = Float(volume()); players[.press]?.play()
        } else {
            guard pressing else { return }; pressing = false
            guard enabled(), volume() > 0, players[.release] != nil else { return }
            let delay = players[.press].map { max(0, $0.duration + 0.06 - Date().timeIntervalSince(pressedAt)) } ?? 0
            let generation = playbackGeneration
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.playbackGeneration == generation, self.enabled(), self.volume() > 0 else { return }
                    self.players[.press]?.stop(); self.players[.release]?.stop()
                    self.players[.release]?.volume = Float(self.volume()); self.players[.release]?.play()
                }
            }
            releaseWork = work
            if delay == 0 { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
        }
    }
    func name(_ slot: AudioSlot) -> String {
        guard let entry = preferences[slot] else { return text("未设置（无声）") }
        if errors[slot] != nil || source(slot, custom: true).map({ !FileManager.default.fileExists(atPath: $0.path) }) == true {
            return text("文件不可用：") + entry.name
        }
        return entry.name
    }
    func canPreview(_ slot: AudioSlot) -> Bool { preferences[slot] != nil && enabled() && volume() > 0 }
    func nativeMenu(target: AnyObject, action: Selector, delegate: NSMenuDelegate) -> NSMenu {
        let menu = NSMenu(); menu.delegate = delegate; menu.autoenablesItems = false
        func item(_ title: String, _ command: String, _ slot: String = "") -> NSMenuItem {
            let entry = NSMenuItem(title: text(title), action: action, keyEquivalent: "")
            entry.target = target; entry.representedObject = [command, slot]; return entry
        }
        menu.addItem(item("使用内置音效", "builtin")); menu.addItem(item("使用自定义音效", "custom"))
        for slot in AudioSlot.allCases {
            let root = NSMenuItem(title: text(slot == .press ? "自定义按下音效" : "自定义松开音效"), action: nil, keyEquivalent: "")
            let sub = NSMenu(); sub.delegate = delegate; sub.autoenablesItems = false
            for (title, command) in [("未设置（无声）", "label"), ("选择WAV…（最长5秒）", "import"), ("设为无声", "clear"), ("试听", "preview")] {
                sub.addItem(item(title, command, slot.rawValue))
            }
            root.submenu = sub; menu.addItem(root)
        }
        return menu
    }
    func updateNativeItem(_ item: NSMenuItem) {
        guard let command = item.representedObject as? [String], command.count == 2 else { return }
        item.isEnabled = !busy
        if command[0] == "builtin" { item.state = preferences.mode == .builtin ? .on : .off }
        if command[0] == "custom" { item.state = preferences.mode == .custom ? .on : .off }
        if let slot = AudioSlot(rawValue: command[1]) {
            if command[0] == "label" { item.title = name(slot); item.isEnabled = false }
            if command[0] == "preview" { item.isEnabled = !busy && canPreview(slot) }
        }
    }
    private func warning(_ message: String) {
        let alert = NSAlert(); alert.messageText = text("GPT 娘 · 音效"); alert.informativeText = message
        alert.alertStyle = .warning; alert.addButton(withTitle: text("确定")); alert.runModal()
    }
    private func convert(_ source: URL, to target: URL) throws {
        guard let executable = node() else { throw AudioImportFailure(text("找不到Node.js，原音效设置已保留。")) }
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = [resources.appendingPathComponent("Backend/runtime/audio-import.mjs").path, source.path, target.path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run()
        let until = Date().addingTimeInterval(5)
        while process.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate(); process.waitUntilExit()
            throw AudioImportFailure(text("音效读取超时，请换一个文件。"))
        }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        guard process.terminationStatus == 0, result?["ok"] as? Bool == true else {
            let key: String
            switch result?["error"] as? String {
            case "too_long": key = "音效超过5秒，请选择不超过5秒的文件。"
            case "too_large": key = "音效文件超过10MiB，请选择较小的文件。"
            case "unsupported": key = "不支持这种WAV编码，请选择其他音效文件。"
            case "io": key = "无法读取或保存音效，请检查文件和个人目录。"
            default: key = "WAV文件损坏或不完整，无法导入。"
            }
            throw AudioImportFailure(text(key))
        }
    }
    func perform(_ action: String, slot: AudioSlot? = nil) {
        guard !busy else { return }; busy = true; defer { busy = false }
        var chosen: URL?
        do {
            switch action {
            case "builtin", "custom":
                var next = preferences; next.mode = action == "builtin" ? .builtin : .custom; try apply(next)
            case "clear":
                guard let slot else { return }; var next = preferences; next.mode = .custom; next[slot] = nil; try apply(next)
            case "preview":
                guard let slot, let file = source(slot, custom: true), enabled(), volume() > 0 else { return }
                guard let sound = NSSound(contentsOf: file, byReference: false), sound.duration.isFinite, sound.duration > 0, sound.duration <= 5 else {
                    throw AudioImportFailure(text("文件不可用，请重新选择。"))
                }
                stop(); preview = sound; sound.volume = Float(volume()); sound.play()
            case "import":
                guard let slot else { return }
                let panel = NSOpenPanel(); panel.allowedContentTypes = [.wav]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
                panel.title = text("选择WAV音效，最长5秒")
                guard panel.runModal() == .OK, let source = panel.url else { return }; chosen = source
                let directory = data.appendingPathComponent("sounds")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let filename = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".wav"
                let target = directory.appendingPathComponent(filename)
                var committed = false
                defer { if !committed { try? FileManager.default.removeItem(at: target) } }
                try convert(source, to: target)
                var next = preferences; next.mode = .custom; next[slot] = AudioEntry(file: filename, name: source.lastPathComponent)
                try apply(next, required: slot); committed = true
            default: return
            }
        } catch {
            let reason = (error as? AudioImportFailure)?.message ?? text("无法读取或保存音效，原设置已保留。")
            warning((chosen.map { $0.lastPathComponent + "\n" } ?? "") + reason)
        }
    }
}
private struct AudioImportFailure: Error { let message: String; init(_ message: String) { self.message = message } }

struct WidgetAudioMenu: View {
    @ObservedObject var audio: WidgetAudio
    var body: some View {
        Menu(audio.text("声音与点击")) {
            Button((audio.preferences.mode == .builtin ? "✓ " : "") + audio.text("使用内置音效")) { audio.perform("builtin") }
            Button((audio.preferences.mode == .custom ? "✓ " : "") + audio.text("使用自定义音效")) { audio.perform("custom") }
            ForEach(AudioSlot.allCases, id: \.self) { slot in
                Menu(audio.text(slot == .press ? "自定义按下音效" : "自定义松开音效")) {
                    Text(audio.name(slot))
                    Button(audio.text("选择WAV…（最长5秒）")) { audio.perform("import", slot: slot) }
                    Button(audio.text("设为无声")) { audio.perform("clear", slot: slot) }
                    Button(audio.text("试听")) { audio.perform("preview", slot: slot) }.disabled(!audio.canPreview(slot))
                }
            }
        }.disabled(audio.busy)
    }
}
