import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

FloatingWindow {
    id: window
    required property var controller
    title: "GPT娘 · 设置"
    implicitWidth: 540
    implicitHeight: 740
    minimumSize: Qt.size(440,480)
    visible: controller.settingsVisible
    onVisibleChanged: {
        if (!visible) controller.settingsVisible = false
        else quoteEditor.text = controller.preferences.customQuotes === null || !controller.preferences.customQuotes ? "" : controller.preferences.customQuotes.join("\n")
    }
    color: palette.window
    SystemPalette { id: palette }

    ScrollView {
        anchors.fill: parent
        anchors.margins: 20
        clip: true
        contentWidth: availableWidth
        ColumnLayout {
            width: parent.width
            spacing: 14
            Label { text: "GPT 娘"; font.pixelSize: 25; font.bold: true }
            Label { text: "额度、语录和桌面陪伴"; opacity: 0.65 }
            Label {
                Layout.fillWidth: true
                text: window.controller.errorMessage || (window.controller.bridgeReady ? "已连接 KWin · " + (window.controller.host.stacking === "constraints" ? "窗口叠放约束" : "窗口叠放兼容模式") : "正在连接 KDE…")
                wrapMode: Text.Wrap
                color: window.controller.errorMessage ? "#ce786e" : palette.text
            }
            GroupBox {
                title: "显示与位置"
                Layout.fillWidth: true
                ColumnLayout {
                    anchors.fill: parent
                    RadioButton { text: "整个桌面自由拖动"; checked: !window.controller.following; onClicked: window.controller.update({mode:"desktop"}) }
                    RadioButton { text: "跟随 Codex 窗口"; checked: window.controller.following; onClicked: window.controller.update({mode:"follow"}) }
                    Label { Layout.fillWidth: true; visible: window.controller.following; text: "拖动时吸附窗口左侧或右侧；主窗口最小化、关闭或离开当前桌面后隐藏。"; wrapMode: Text.Wrap; opacity: 0.65 }
                    CheckBox { text: "始终置顶"; visible: !window.controller.following; checked: window.controller.preferences.alwaysOnTop; onClicked: window.controller.update({alwaysOnTop:checked}) }
                    RowLayout {
                        Label { text: "缩放" }
                        Slider {
                            Layout.fillWidth: true
                            from: 0.6; to: 2.5; stepSize: 0.05
                            value: window.controller.preferences.scale
                            onMoved: window.controller.update({scale:value})
                        }
                        Label { text: Math.round(window.controller.preferences.scale*100) + "%"; Layout.preferredWidth: 45 }
                    }
                    RowLayout {
                        Repeater {
                            model: [0.8,1,1.4]
                            Button { required property real modelData; text: Math.round(modelData*100)+"%"; onClicked: window.controller.update({scale:modelData}) }
                        }
                        Button { text: "重置位置"; onClicked: window.controller.update({desktop:{x:null,y:null},follow:{edge:"right",bottom:16}}) }
                    }
                }
            }
            GroupBox {
                title: "声音与点击"
                Layout.fillWidth: true
                ColumnLayout {
                    anchors.fill: parent
                    CheckBox { text: "播放按压和回弹音效"; checked: window.controller.preferences.sound; onClicked: window.controller.update({sound:checked}) }
                    Slider { Layout.fillWidth: true; from: 0; to: 1; value: window.controller.preferences.volume; onMoved: window.controller.update({volume:value}) }
                    CheckBox { text: "点击角色切换额度、语录与收起"; checked: window.controller.preferences.clickCycles; onClicked: window.controller.update({clickCycles:checked}) }
                    RowLayout {
                        Label { text: "气泡停留" }
                        SpinBox { from: 3; to: 60; value: window.controller.preferences.bubbleSeconds; onValueModified: window.controller.update({bubbleSeconds:value}) }
                        Label { text: "秒" }
                    }
                }
            }
            GroupBox {
                title: "当前额度"
                Layout.fillWidth: true
                ColumnLayout {
                    anchors.fill: parent
                    Repeater {
                        model: window.controller.rows
                        Label { required property var modelData; Layout.fillWidth: true; text: modelData.label+"："+modelData.value+"   重置："+modelData.resetLabel+(modelData.stale?"（上次数据）":""); wrapMode: Text.Wrap }
                    }
                    Label { Layout.fillWidth: true; visible: !!window.controller.quota.error; text: window.controller.quota.error || ""; wrapMode: Text.Wrap }
                    Button { text: window.controller.busy ? "刷新中…" : "刷新额度"; enabled: !window.controller.busy; onClicked: window.controller.send({command:"refresh"}) }
                }
            }
            GroupBox {
                title: "自定义语录"
                Layout.fillWidth: true
                ColumnLayout {
                    anchors.fill: parent
                    Label { text: "每行一句，最多 200 句。留空保存后不显示语录。"; wrapMode: Text.Wrap; Layout.fillWidth: true; opacity: 0.65 }
                    TextArea { id: quoteEditor; Layout.fillWidth: true; Layout.preferredHeight: 120; placeholderText: "当前使用内置语录"; wrapMode: TextEdit.Wrap; selectByMouse: true }
                    RowLayout {
                        Button { text: "保存语录"; onClicked: window.controller.update({customQuotes:quoteEditor.text.split("\n")}) }
                        Button { text: "恢复内置"; onClicked: {quoteEditor.text="";window.controller.update({customQuotes:null})} }
                        Button { text: "显示一句"; onClicked: window.controller.nextQuote() }
                    }
                }
            }
            CheckBox { text: "登录 KDE 时启动"; checked: window.controller.autostart; onClicked: window.controller.send({command:"autostart",enabled:checked}) }
            Label { Layout.fillWidth: true; text: "Linux KDE 预览版 · 基于上游 1.3.4\n程序更新请在安装目录使用 Git 或替换完整 Linux 包，个人设置独立保留。"; wrapMode: Text.Wrap; opacity: 0.6 }
            RowLayout {
                Button { text: "退出 GPT 娘"; onClicked: window.controller.quit() }
                Item { Layout.fillWidth: true }
                Button { text: "完成"; onClicked: window.controller.settingsVisible = false }
            }
        }
    }
}
