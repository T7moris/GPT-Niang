import QtQuick
import QtQuick.Controls
import QtMultimedia
import Quickshell

FloatingWindow {
    id: window
    required property var controller
    property alias hovered: hover.hovered
    readonly property real factor: controller.preferences.scale || 1
    title: "GPT娘 · KDE 挂件"
    color: "transparent"
    visible: controller.petVisible
    implicitWidth: Math.round(280 * factor)
    implicitHeight: Math.round(362 * factor)
    minimumSize: Qt.size(implicitWidth,implicitHeight)
    maximumSize: Qt.size(implicitWidth,implicitHeight)
    function capture(file) { canvas.grabToImage(function(result) { result.saveToFile(file) }) }

    mask: Region {
        Region { item: characterHit; shape: RegionShape.Ellipse }
        Region {
            x: bubble.x * window.factor
            y: bubble.y * window.factor
            width: bubble.visible ? bubble.width * window.factor : 0
            height: bubble.visible ? bubble.height * window.factor : 0
        }
        Region {
            x: buttons.x * window.factor
            y: buttons.y * window.factor
            width: buttons.visible ? buttons.width * window.factor : 0
            height: buttons.visible ? buttons.height * window.factor : 0
        }
    }
    SoundEffect { id: pressSound; source: Qt.resolvedUrl("../../gpt-niang-usage/assets/press.wav"); volume: window.controller.preferences.volume || 0 }
    SoundEffect { id: releaseSound; source: Qt.resolvedUrl("../../gpt-niang-usage/assets/release.wav"); volume: window.controller.preferences.volume || 0 }

    Item {
        id: canvas
        width: 280
        height: 362
        scale: window.factor
        transformOrigin: Item.TopLeft
        HoverHandler { id: hover }

        Rectangle {
            id: bubble
            x: 6; y: 4
            width: 268
            height: window.controller.bubbleMode === "quote" ? Math.max(100,quoteLabel.implicitHeight + 44) : 136
            radius: 18
            color: "#faf7ff"
            border.color: "#c9b6e6"
            border.width: 2
            visible: window.controller.bubbleMode !== "hidden"
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 160 } }
            MouseArea { anchors.fill: parent; onClicked: window.controller.cycle() }
            Text {
                x: 15; y: 11
                text: window.controller.bubbleMode === "quote" ? "GPT 娘" : "Codex · " + (window.controller.quota.planLabel || "额度")
                color: "#6d568b"
                font.pixelSize: 12
                font.bold: true
            }
            ToolButton {
                x: parent.width - 39; y: 0
                width: 36; height: 36
                text: window.controller.busy ? "⋯" : "↻"
                font.pixelSize: 21
                visible: window.controller.bubbleMode === "quota"
                enabled: !window.controller.busy
                onClicked: window.controller.send({command:"refresh"})
                ToolTip.visible: hovered
                ToolTip.text: "刷新额度"
            }
            Column {
                x: 15; y: 36
                width: parent.width - 30
                spacing: 8
                visible: window.controller.bubbleMode === "quota"
                Repeater {
                    model: window.controller.rows.slice(0,2)
                    delegate: Column {
                        required property var modelData
                        width: 238
                        spacing: 3
                        Row {
                            width: parent.width
                            Text { width: 140; text: modelData.label; color: "#695480"; font.pixelSize: 13 }
                            Text { width: 98; horizontalAlignment: Text.AlignRight; text: modelData.value; color: modelData.expired ? "#aa7867" : "#574071"; font.pixelSize: 15; font.bold: true }
                        }
                        Rectangle {
                            width: parent.width; height: 5; radius: 3; color: "#e5dbee"
                            Rectangle { width: parent.width * Math.max(0,Math.min(1,(modelData.remaining || 0)/100)); height: 5; radius: 3; color: modelData.expired || modelData.stale ? "#b8a6c3" : "#a98acb" }
                        }
                    }
                }
                Text {
                    width: parent.width
                    text: window.controller.rows.length ? ((window.controller.rows.some(w => w.expired) ? "等待重置后的新数据" : window.controller.rows.some(w => w.stale) ? "上次额度 · 点击刷新重试" : "剩余额度 · 点击气泡切换语录")) : (window.controller.quota.error || "当前账户未提供额度窗口")
                    wrapMode: Text.WordWrap
                    maximumLineCount: window.controller.rows.length ? 1 : 3
                    elide: Text.ElideRight
                    font.pixelSize: 10
                    color: "#927fa2"
                }
            }
            Text {
                id: quoteLabel
                x: 16; y: 36
                width: parent.width - 32
                text: window.controller.quoteText
                wrapMode: Text.Wrap
                font.pixelSize: 16
                lineHeight: 1.2
                color: "#67507f"
                visible: window.controller.bubbleMode === "quote"
            }
        }
        Item {
            id: character
            x: window.controller.following && window.controller.preferences.follow && window.controller.preferences.follow.edge === "left" ? 4 : 48
            y: 142
            width: 220; height: 220
            transformOrigin: Item.Bottom
            scale: mouse.pressed && !window.controller.dragging ? 0.95 : 1
            Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
            Item { id: characterHit; x: 8; y: 4; width: 205; height: 216 }
            Image {
                anchors.fill: parent
                source: Qt.resolvedUrl("../../gpt-niang-usage/assets/gpt-dragon-niang-bust.png")
                sourceSize: Qt.size(600,600)
                fillMode: Image.PreserveAspectFit
                mirror: window.controller.following && window.controller.preferences.follow && window.controller.preferences.follow.edge === "left"
                smooth: true
            }
            MouseArea {
                id: mouse
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                property point start
                property point offset
                onPressed: event => {
                    start = Qt.point(event.x,event.y)
                    offset = character.mapToItem(window.contentItem,event.x,event.y)
                    if (event.button === Qt.LeftButton && window.controller.preferences.sound) pressSound.play()
                }
                onPositionChanged: event => {
                    if (!pressed || pressedButtons !== Qt.LeftButton) return
                    if (!window.controller.dragging && Math.abs(event.x-start.x)+Math.abs(event.y-start.y)>7) {
                        window.controller.dragging = true
                        window.controller.send({command:"dragStart",x:offset.x,y:offset.y})
                    }
                }
                onReleased: event => {
                    if (window.controller.dragging) {
                        window.controller.send({command:"dragEnd"})
                        window.controller.dragging = false
                    } else if (event.button === Qt.RightButton) {
                        window.controller.settingsVisible = true
                    } else {
                        if (window.controller.preferences.sound) releaseSound.play()
                        window.controller.characterClicked()
                    }
                }
                onCanceled: {
                    if (window.controller.dragging) window.controller.send({command:"dragEnd"})
                    window.controller.dragging = false
                }
                onWheel: event => {
                    var next = Math.max(0.6,Math.min(2.5,window.factor+(event.angleDelta.y>0?0.05:-0.05)))
                    window.controller.update({scale:next})
                    event.accepted = true
                }
            }
        }
        Row {
            id: buttons
            x: 8; y: 160
            spacing: 4
            visible: hover.hovered && !window.controller.dragging
            ToolButton { text: "⚙"; width: 32; height: 32; onClicked: window.controller.settingsVisible = true; ToolTip.visible: hovered; ToolTip.text: "设置" }
        }
    }
}
