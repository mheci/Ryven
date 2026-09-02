import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

ShellRoot {
    PanelWindow {
        anchors {
            top: true
            left: true
            right: true
        }
        implicitHeight: 34
        color: "#1e1e2e"

        Text {
            anchors.centerIn: parent
            color: "#cdd6f4"
            font.family: "Inter"
            font.pixelSize: 13
            text: "Ryven WL  ·  Hyprland  ·  SUPER+D launcher  ·  SUPER+Return terminal"
        }
    }
}
