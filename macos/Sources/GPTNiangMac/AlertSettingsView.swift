import SwiftUI
import GPTNiangCore

struct AlertSettingsView: View {
    @ObservedObject var model: WidgetModel
    var body: some View {
        GroupBox(model.text("额度与任务提醒")) {
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
                Toggle(model.text("短时额度重置提醒"), isOn: $model.alertPreferences.shortResetEnabled)
                Toggle(model.text("周额度重置提醒"), isOn: $model.alertPreferences.weekResetEnabled)
                Text(model.text("刷新确认进入新周期后提醒一次，与不足提醒独立。首次开启不补报；使用额度提醒的声音设置，后台仍每 60 秒检查。"))
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle(model.text("本轮结束提醒"), isOn: $model.alertPreferences.completionEnabled)
                Toggle(model.text("声音 · 本轮结束"), isOn: $model.alertPreferences.completionSoundEnabled)
                    .disabled(!model.alertPreferences.completionEnabled)
                tonePicker($model.alertPreferences.completionTone)
                Toggle(model.text("后台弹出 · 本轮结束"), isOn: $model.alertPreferences.completionPopupEnabled)
                    .disabled(!model.alertPreferences.completionEnabled)
                Text(model.text("无法分类的新通知显示“ChatGPT 有新提醒，请查看”，沿用本轮结束提醒的声音与弹出设置。"))
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle(model.text("命令与权限请求提醒"), isOn: $model.alertPreferences.commandEnabled)
                Toggle(model.text("声音 · 需要授权"), isOn: $model.alertPreferences.commandSoundEnabled)
                    .disabled(!model.alertPreferences.commandEnabled)
                tonePicker($model.alertPreferences.commandTone)
                Toggle(model.text("后台弹出 · 需要授权"), isOn: $model.alertPreferences.commandPopupEnabled)
                    .disabled(!model.alertPreferences.commandEnabled)
                Divider()
                Toggle(model.text("回答问题提醒"), isOn: $model.alertPreferences.questionEnabled)
                Toggle(model.text("声音 · 需要回答"), isOn: $model.alertPreferences.questionSoundEnabled)
                    .disabled(!model.alertPreferences.questionEnabled)
                tonePicker($model.alertPreferences.questionTone)
                Toggle(model.text("后台弹出 · 需要回答"), isOn: $model.alertPreferences.questionPopupEnabled)
                    .disabled(!model.alertPreferences.questionEnabled)
                Text(model.text("声音使用当前音量。后台弹出仅用于跟随模式，显示约 6 秒，不抢焦点。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.text("接收应用实际发出的通知，请在宿主通知设置中启用完成、权限和问题提醒。只读取通知类型与标识，不读取提示正文。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.text("ChatGPT 与 Codex 通知使用相同分类；其他权限请求显示“需要你的授权”。通知关闭或日志格式变化可能导致无法提醒。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.text("文件变化时读取新增记录，每 30 秒补查。本机 Codex 保留最近十二个会话的完成监测；不补报历史提醒。"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(model.text("额度与测试提醒声音"), isOn: $model.alertPreferences.soundEnabled)
                tonePicker($model.alertPreferences.quotaTone)
                HStack {
                    Button(model.text("测试命令授权")) { model.alerts.testTask(.command) }
                    Button(model.text("测试回答问题")) { model.alerts.testTask(.question) }
                    Button(model.text("测试本轮结束")) { model.alerts.testTask(.completion) }
                }
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
    private func tonePicker(_ selection: Binding<AlertSound>) -> some View {
        HStack {
            Picker(model.text("提示音"), selection: selection) {
                ForEach(AlertSound.allCases, id: \.self) { tone in
                    Text(model.text(tone.titleKey)).tag(tone)
                }
            }
            Button(model.text("试听")) { model.playAlertSound(selection.wrappedValue) }
                .disabled(model.volume <= 0)
        }
    }

}
