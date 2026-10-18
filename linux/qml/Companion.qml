//@ pragma UseQApplication
//@ pragma Env QS_NO_RELOAD_POPUP=1
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root
    property var preferences: ({mode:"desktop",scale:1,alwaysOnTop:false,sound:true,volume:0.35,clickCycles:false,bubbleSeconds:5})
    property var quota: ({windows:[],error:"正在读取额度…"})
    property var rows: []
    property var quotes: []
    property var host: ({})
    property bool bridgeReady: false
    property bool busy: false
    property bool autostart: false
    property bool settingsVisible: false
    property bool exiting: false
    property string errorMessage: ""
    property string bubbleMode: "quota"
    property string quoteText: ""
    property bool dragging: false
    readonly property bool following: preferences.mode === "follow"
    readonly property bool petVisible: bridgeReady && (!following || !!(host.target && host.target.visible))

    function send(command) {
        if (companion.running) companion.write(JSON.stringify(command) + "\n")
    }
    function update(patch) { send({command:"settings",patch:patch}) }
    function showQuota() { bubbleMode = "quota"; bubbleTimeout.restart() }
    function nextQuote() {
        quoteText = quotes.length ? quotes[Math.floor(Math.random() * quotes.length)] : "在设置中添加一句语录吧。"
        bubbleMode = "quote"
        bubbleTimeout.restart()
    }
    function cycle() {
        if (bubbleMode === "quota") nextQuote()
        else if (bubbleMode === "quote") bubbleMode = "hidden"
        else showQuota()
    }
    function characterClicked() {
        if (preferences.clickCycles) cycle()
        else showQuota()
    }
    function quit() {
        exiting = true
        send({command:"quit"})
        exitTimer.start()
    }
    function state() {
        return JSON.stringify({ready:bridgeReady,visible:petVisible,windowVisible:pet.backingWindowVisible,windowSize:{width:pet.width,height:pet.height},preferences:preferences,host:host,quota:quota,rows:rows,busy:busy,error:errorMessage,bubble:bubbleMode})
    }

    Process {
        id: companion
        command: [Quickshell.env("GPT_NIANG_NODE") || "node", decodeURIComponent(Qt.resolvedUrl("../runtime/companion.mjs").toString().replace(/^file:\/\//, ""))]
        running: true
        stdinEnabled: true
        stdout: SplitParser {
            onRead: line => {
                var event
                try { event = JSON.parse(line) } catch (_) { return }
                if (event.type === "init" || event.type === "settings") {
                    root.preferences = event.settings
                    root.quotes = event.quotes
                    root.autostart = event.autostart
                } else if (event.type === "usage") {
                    root.quota = event.snapshot
                    root.rows = event.windows
                    root.busy = event.busy
                } else if (event.type === "host") {
                    root.host = event.host
                } else if (event.type === "bridge") {
                    root.bridgeReady = event.ready
                    root.errorMessage = event.error || ""
                    if (!event.ready) root.settingsVisible = true
                } else if (event.type === "error") {
                    root.errorMessage = event.error
                }
            }
        }
        stderr: SplitParser { onRead: line => console.warn(line) }
        onExited: (exitCode, exitStatus) => {
            root.bridgeReady = false
            if (!root.exiting) {
                root.errorMessage = "后台已退出，正在重新启动…"
                restartTimer.restart()
            }
        }
    }
    Timer { id: restartTimer; interval: 3000; onTriggered: companion.running = true }
    Timer { id: exitTimer; interval: 650; onTriggered: Qt.quit() }
    Timer {
        id: bubbleTimeout
        interval: (root.preferences.bubbleSeconds || 5) * 1000
        running: true
        onTriggered: if (!root.dragging && !pet.hovered) root.bubbleMode = "hidden"; else restart()
    }
    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.send({command:"presence",visible:root.petVisible})
    }
    IpcHandler {
        target: "pet"
        function status(): string { return root.state() }
        function settings(): void { root.settingsVisible = true }
        function refresh(): void { root.send({command:"refresh"}) }
        function showQuota(): void { root.showQuota() }
        function quote(): void { root.nextQuote() }
        function capture(file: string): void {
            pet.capture(file)
        }
        function hideBubble(): void { root.bubbleMode = "hidden" }
        function setMode(mode: string): string {
            if (mode !== "desktop" && mode !== "follow") return "mode 必须为 desktop 或 follow"
            root.update({mode:mode}); return mode
        }
        function setScale(value: string): string {
            var scale = Number(value)
            if (!isFinite(scale) || scale < 0.6 || scale > 2.5) return "scale 必须为 0.6–2.5"
            root.update({scale:scale}); return String(scale)
        }
        function quit(): void { root.quit() }
    }
    PetWindow { id: pet; controller: root }
    SettingsWindow { controller: root }
}
