import Foundation
import MachO

public enum HostLinkInstallation {
    /// SMAppService may supply a relative argv[0] even with the working directory
    /// set to /. Ask dyld for the executable instead of interpreting argv[0].
    public static func currentApplicationURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var path = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&path, &size) == 0 else { return nil }
        return applicationURL(executablePath: String(cString: path))
    }

    public static func applicationURL(executablePath: String) -> URL? {
        guard executablePath.hasPrefix("/") else { return nil }
        let executable = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        let helpers = executable.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard executable.lastPathComponent == "GPTNiangHostLink",
              helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return app
    }
}

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
