import AppKit
import GPTNiangCore
import os

/// A separate agent must survive the pet's exit to observe the next host launch.
@main struct HostLinkEntry {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = HostLinkDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor final class HostLinkDelegate: NSObject, NSApplicationDelegate {
    private var state = HostLinkState()
    private var timer: Timer?
    private var opening = false
    private let logger = Logger(subsystem: "io.github.t7moris.GPTNiangMac", category: "host-link")
    // The agent is bundled in Contents/Helpers; resolve this installation, not a
    // similarly named app returned by Launch Services or another build checkout.
    private let appURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var preferencesURL: URL {
        let args = CommandLine.arguments
        // Isolated integration checks can use a disposable data directory.
        if let i = args.firstIndex(of: "--data-dir"), args.indices.contains(i + 1) {
            return URL(fileURLWithPath: args[i + 1]).appendingPathComponent("preferences.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GPTNiangUsage/preferences.json")
    }
    private func preferences() -> HostLinkPreferences {
        guard let data = try? Data(contentsOf: preferencesURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["hostLink"], let encoded = try? JSONSerialization.data(withJSONObject: raw),
              let prefs = try? JSONDecoder().decode(HostLinkPreferences.self, from: encoded)
        else { return HostLinkPreferences() }
        return prefs
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(self, selector: #selector(applicationChanged), name: name, object: nil)
        }
        reconcile(event: "startup")
        // Workspace notifications may be coalesced or absent for background
        // executables. Reconcile PIDs as a fallback, without reopening a manually
        // quit pet while the same host process stays alive.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcile(event: "poll") }
        }
    }
    @objc private func applicationChanged(_ notification: Notification) {
        if CommandLine.arguments.contains("--trace") {
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let line = "notification launch=\(notification.name == NSWorkspace.didLaunchApplicationNotification) hasApp=\(app != nil) matches=\(app?.bundleIdentifier == preferences().bundleIdentifier)\n"
            try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
        }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == preferences().bundleIdentifier else { return }
        reconcile(event: notification.name == NSWorkspace.didLaunchApplicationNotification ? "launch" : "terminate")
    }
    private func reconcile(event: String) {
        let prefs = preferences()
        let processes = Set(NSRunningApplication.runningApplications(withBundleIdentifier: prefs.bundleIdentifier)
            .filter { !$0.isTerminated }.map(\.processIdentifier))
        let action = state.observe(enabled: prefs.enabled, hostProcesses: processes)
        if CommandLine.arguments.contains("--trace") {
            let line = "\(event) running=\(!processes.isEmpty) action=\(action)\n"
            try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
        }
        switch action {
        case .none: break
        case .launch:
            guard !opening, matchingPets().isEmpty else { return }
            opening = true
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.arguments = ["--linked-launch"]
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] app, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.opening = false
                    if let error { self.logger.error("Pet launch failed: \(error.localizedDescription, privacy: .public)") }
                    let current = self.preferences()
                    if current.enabled && !NSRunningApplication.runningApplications(withBundleIdentifier: current.bundleIdentifier)
                        .contains(where: { !$0.isTerminated }), app?.bundleURL?.resolvingSymlinksInPath() == self.appURL {
                        app?.terminate()
                    }
                }
            }
        case .quit:
            // Graceful application exit runs normal worker/presence cleanup.
            // Never terminate the host, other installations, or apps by name.
            for pet in matchingPets() { pet.terminate() }
        }
    }
    private func matchingPets() -> [NSRunningApplication] {
        guard let identifier = Bundle(url: appURL)?.bundleIdentifier else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter {
            $0.bundleURL?.resolvingSymlinksInPath() == appURL && !$0.isTerminated
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
