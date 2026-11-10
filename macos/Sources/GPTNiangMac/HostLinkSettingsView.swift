import SwiftUI
import ServiceManagement
import GPTNiangCore

@MainActor enum HostLinkRegistration {
    static var service: SMAppService { .agent(plistName: HostLinkPreferences.servicePlistName) }
    static func setEnabled(_ enabled: Bool, model: WidgetModel) throws {
        let previous = model.hostLinkPreferences
        model.hostLinkPreferences.enabled = enabled
        guard model.savePreferences() else {
            model.hostLinkPreferences = previous
            throw CocoaError(.fileWriteUnknown)
        }
        // Persist before registration: the helper may start immediately.
        do {
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            } else if service.status != .notRegistered { try service.unregister() }
        } catch {
            model.hostLinkPreferences = previous; model.savePreferences()
            throw error
        }
    }
}

struct HostLinkSettingsView: View {
    @ObservedObject var model: WidgetModel
    @State private var error: String?
    @State private var needsApproval = false
    private var hostName: String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: model.hostLinkPreferences.bundleIdentifier)
            .map { FileManager.default.displayName(atPath: $0.path) } ?? "ChatGPT"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(model.text("随当前应用启动与退出"), isOn: Binding(
                get: { model.hostLinkPreferences.enabled }, set: { value in
                    do { try HostLinkRegistration.setEnabled(value, model: model); error = nil }
                    catch { self.error = model.text("应用联动设置失败：%@", error.localizedDescription) }
                    refreshStatus()
                }))
            Text(model.text("联动应用：%@", hostName)).font(.caption)
            Text(model.text("应用启动时打开桌宠，彻底退出时关闭桌宠。关闭窗口或最小化不算退出。轻量后台监听器会在登录后继续等待应用启动。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if needsApproval {
                Text(model.text("请在系统设置的「登录项与扩展」允许 GPT 娘的后台活动，联动才会生效。"))
                    .font(.caption).foregroundStyle(.orange)
                Button(model.text("打开登录项设置")) { SMAppService.openSystemSettingsLoginItems() }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.onAppear { refreshStatus() }
         .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshStatus() }
    }
    private func refreshStatus() {
        needsApproval = model.hostLinkPreferences.enabled && HostLinkRegistration.service.status == .requiresApproval
    }
}
