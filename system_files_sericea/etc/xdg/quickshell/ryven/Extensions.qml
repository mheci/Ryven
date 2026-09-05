// Drop-in widget loader: every *.qml file in the ryven/extensions/
// directories (system + user) is instantiated in sorted order inside the
// bar. Adding, removing, or renaming a file there changes the bar on the
// next reload — and saving any config file under ~/.config/quickshell
// reloads the bar automatically (quickshell-reload.path). Contract per
// extension: root is an Item sized for the bar (height <= 22 px),
// self-contained. A broken extension logs a warning and is skipped; it
// cannot kill the bar.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: ext
    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight
    property var files: []

    function reload() {
        scan.running = true
    }

    Component.onCompleted: ext.reload()

    Process {
        id: scan
        // System extensions first, user extensions after (sorted paths).
        command: ["sh", "-c", "find /etc/xdg/quickshell/ryven/extensions \"$HOME/.config/quickshell/ryven/extensions\" -maxdepth 1 -name '*.qml' 2>/dev/null | sort"]
        running: false
        onExited: function(exitCode, stdout, stderr) {
            scan.running = false
            var out = stdout.trim()
            ext.files = out ? out.split("\n") : []
        }
    }

    Row {
        id: row
        spacing: 6
        Repeater {
            model: ext.files
            delegate: Loader {
                required property var modelData
                anchors.verticalCenter: parent.verticalCenter
                source: "file://" + modelData
                onStatusChanged: if (status === Loader.Error)
                    console.warn("ryven bar: extension failed to load:", modelData)
            }
        }
    }
}
