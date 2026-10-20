import Foundation

public enum AudioSlot: String, CaseIterable, Hashable { case press, release }
public struct AudioEntry: Codable, Equatable {
    public var file: String
    public var name: String
    public init(file: String, name: String) { self.file = file; self.name = name }
}
public struct AudioPreferences: Codable, Equatable {
    public enum Mode: String, Codable { case builtin, custom }
    public var version = 1
    public var mode: Mode = .builtin
    public var press: AudioEntry?
    public var release: AudioEntry?
    public init() {}
    public subscript(_ slot: AudioSlot) -> AudioEntry? {
        get { slot == .press ? press : release }
        set { if slot == .press { press = newValue } else { release = newValue } }
    }
    public static func decode(_ data: Data) throws -> AudioPreferences {
        guard data.count <= 16384 else { throw CocoaError(.fileReadCorruptFile) }
        let value = try JSONDecoder().decode(AudioPreferences.self, from: data)
        guard value.version == 1, AudioSlot.allCases.allSatisfy({ slot in
            guard let entry = value[slot] else { return true }
            return entry.name.utf16.count <= 255 && entry.file.range(of: "^[a-f0-9]{32}\\.wav$", options: .regularExpression) != nil
        }) else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
}
