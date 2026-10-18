import QtQuick
import QtQuick.Controls
import QtMultimedia
import Quickshell
import Quickshell.Io

ShellRoot {
    FloatingWindow { visible: false; Button { text: "check" } }
    SoundEffect { volume: 0 }
    Process {}
    Timer { interval: 100; running: true; onTriggered: {console.warn("GPT_NIANG_QML_OK");Qt.quit()} }
}
