import Foundation

/// Links application lifetimes, independent of windows, foreground state or chats.
public struct HostLinkPreferences: Codable, Equatable {
    public static let servicePlistName = "io.github.t7moris.GPTNiangMac.HostLink.plist"
    public var enabled = false
    public var bundleIdentifier = "com.openai.codex"
    public init() {}
    private enum CodingKeys: String, CodingKey { case enabled, bundleIdentifier }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        bundleIdentifier = try values.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? "com.openai.codex"
    }
}

public struct HostLinkState {
    public enum Action: Equatable { case none, launch, quit }
    private var previousProcesses: Set<Int32>?
    public init() {}
    public mutating func observe(enabled: Bool, hostProcesses: Set<Int32>) -> Action {
        guard enabled else { previousProcesses = nil; return .none }
        defer { previousProcesses = hostProcesses }
        guard previousProcesses != hostProcesses else { return .none }
        if !hostProcesses.isEmpty {
            return hostProcesses.isSubset(of: previousProcesses ?? []) ? .none : .launch
        }
        return previousProcesses?.isEmpty == false ? .quit : .none
    }
}
