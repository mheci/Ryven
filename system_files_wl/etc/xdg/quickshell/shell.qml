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
        // Ryven Navy (coolors 0d1b2a-1b263b-415a77-778da9-e0e1dd)
        color: "#142032"

        Text {
            anchors.centerIn: parent
            color: "#e0e1dd"
            font.family: "Inter"
            font.pixelSize: 13
            text: "Ryven WL  ·  Hyprland  ·  SUPER+D launcher  ·  SUPER+Return terminal"
        }
    }
}
