import SwiftUI
import GPTNiangCore

struct AlertSettingsView: View {
    @ObservedObject var model: WidgetModel
    var body: some View {
        GroupBox(model.text("额度与完成提醒")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(model.text("短时额度提醒"), isOn: $model.alertPreferences.shortEnabled)
                if model.alertPreferences.shortEnabled {
                    Stepper(model.text("剩余 %@%% 时提醒", String(model.alertPreferences.shortThreshold)),
                            value: $model.alertPreferences.shortThreshold, in: 1...99)
                }
                Toggle(model.text("周额度提醒"), isOn: $model.alertPreferences.weekEnabled)
                if model.alertPreferences.weekEnabled {
                    Stepper(model.text("剩余 %@%% 时提醒", String(model.alertPreferences.weekThreshold)),
                            value: $model.alertPreferences.weekThreshold, in: 1...99)
                }
                Text(model.text("低于或等于阈值提醒一次，耗尽时再提醒；恢复后重新计数。启用后即使桌宠隐藏，也会每 60 秒检查额度。"))
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle(model.text("Codex 本轮结束气泡"), isOn: $model.alertPreferences.completionEnabled)
                Toggle(model.text("后台短暂显示桌宠（仅跟随模式）"), isOn: $model.alertPreferences.completionPopupEnabled)
                    .disabled(!model.alertPreferences.completionEnabled)
                Text(model.text("与提醒声音独立：切到其他窗口后，在当前屏幕右下角显示约 6 秒，不抢焦点、不改变桌面位置。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.text("每 3 秒检查最近十二个本机会话，仅提醒启用后观察到开始和结束的回复。取消不提醒，关闭速度面板不影响监测。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.text("普通 ChatGPT 无法由挂件监测，请在 ChatGPT 设置 → 通知中启用完成提醒。Codex 系统通知也使用其原生设置。"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(model.text("提醒声音（使用当前音量）"), isOn: $model.alertPreferences.soundEnabled)
                Text(model.text("声音在事件到达时提示。未开启后台短暂显示时，气泡等待桌宠可见且操作结束后显示，超过两分钟自动忽略。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(model.text("测试提醒")) { model.alerts.test() }
                    Button(model.text("打开系统通知设置")) { model.alerts.openNotificationSettings() }
                }
                if model.alertPermissionDenied {
                    Text(model.text("系统通知未获允许，桌宠气泡仍可使用。请在系统设置中允许 GPT 娘通知。"))
                        .font(.caption).foregroundStyle(.orange)
                }
                if let error = model.alertMonitorError { Text(error).font(.caption).foregroundStyle(.orange) }
                if let error = model.alertStorageError { Text(error).font(.caption).foregroundStyle(.orange) }
            }.padding(10)
        }
    }
}
