// Ryven-Kunzite bar (Hyprland): intentionally minimal — a centered hint and
// a right-hand cluster of drop-in extensions plus the clock. Everything else
// is meant to be added through ryven/extensions/ or by asking pi
// (`ujust customize-bar`). Palette: Ryven Navy (0d1b2a-1b263b-415a77-
// 778da9-e0e1dd); Qt color literals are #AARRGGBB (alpha first).
import QtQuick
import Quickshell

Item {
    id: root

    PanelWindow {
        id: bar
        anchors {
            top: true
            left: true
            right: true
        }
        implicitHeight: 34
        color: "#142032"

        Text {
            anchors.centerIn: parent
            color: "#e0e1dd"
            font.family: "Inter"
            font.pixelSize: 13
            text: "Ryven WL  ·  Hyprland  ·  SUPER+D launcher  ·  SUPER+Return terminal"
        }

        // Right: drop-in extensions + clock.
        Row {
            anchors {
                right: parent.right
                rightMargin: 8
                verticalCenter: parent.verticalCenter
            }
            spacing: 8

            Extensions {
                anchors.verticalCenter: parent.verticalCenter
            }

            Text {
                id: clockText
                anchors.verticalCenter: parent.verticalCenter
                color: "#e0e1dd"
                font.family: "Inter"
                font.pixelSize: 13
            }
        }

        Timer {
            interval: 1000
            running: true
            repeat: true
            triggeredOnStart: true
            onTriggered: clockText.text = Qt.formatDateTime(new Date(), "ddd d MMM  HH:mm")
        }
    }
}
