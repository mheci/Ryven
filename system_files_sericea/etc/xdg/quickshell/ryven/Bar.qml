// Ryven-Sericea bar: Quickshell over wlr-layer-shell (replaces waybar).
// Workspaces come from swaymsg (get_workspaces + subscribe); the tray is
// the StatusNotifier service; the right cluster is drop-in extensions +
// clock. Qt color literals are #AARRGGBB (alpha first). Ryven Navy palette
// (coolors 0d1b2a-1b263b-415a77-778da9-e0e1dd). AI agents: extend via
// ryven/extensions/ first; see ../AGENTS.md.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.SystemTray

Item {
    id: root

    function refreshWorkspaces() {
        wsFetch.running = true
    }

    Component.onCompleted: root.refreshWorkspaces()

    Process {
        id: wsFetch
        command: ["swaymsg", "-t", "get_workspaces"]
        running: false
        onExited: function(exitCode, stdout, stderr) {
            wsFetch.running = false
            if (exitCode !== 0)
                return
            try {
                bar.workspaces = JSON.parse(stdout)
            } catch (e) {
                console.warn("ryven bar: swaymsg parse failed:", e)
            }
        }
    }

    Process {
        // Monitor mode: sway prints one JSON event per line.
        command: ["swaymsg", "-t", "subscribe", "-m", '["workspace","window"]']
        running: true
        onStdout: function(line) {
            root.refreshWorkspaces()
        }
    }

    Process {
        id: wsSwitch
        running: false
    }

    SystemTray {
        id: tray
    }

    PanelWindow {
        id: bar
        property var workspaces: []

        anchors {
            top: true
            left: true
            right: true
        }
        implicitHeight: 32
        color: "#142032"

        Timer {
            interval: 1000
            running: true
            repeat: true
            triggeredOnStart: true
            onTriggered: clockText.text = Qt.formatDateTime(new Date(), "ddd d MMM  HH:mm")
        }

        // Left: workspace buttons.
        Row {
            anchors {
                left: parent.left
                leftMargin: 8
                verticalCenter: parent.verticalCenter
            }
            spacing: 4
            Repeater {
                model: bar.workspaces
                delegate: Rectangle {
                    id: wsItem
                    required property var modelData
                    width: wsLabel.implicitWidth + 16
                    height: 22
                    radius: 6
                    color: wsItem.modelData.focused ? "#415a77" : (wsItem.modelData.urgent ? "#d98a8a" : "transparent")
                    border.width: 1
                    border.color: wsItem.modelData.focused ? "#778da9" : "#80415a77"

                    Text {
                        id: wsLabel
                        anchors.centerIn: parent
                        text: wsItem.modelData.name
                        color: wsItem.modelData.focused ? "#e0e1dd" : "#778da9"
                        font.family: "Inter"
                        font.pixelSize: 13
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            wsSwitch.command = ["swaymsg", "workspace", wsItem.modelData.name]
                            wsSwitch.running = true
                        }
                    }
                }
            }
        }

        // Center: image label.
        Text {
            anchors.centerIn: parent
            text: "Ryven SL"
            color: "#e0e1dd"
            font.family: "Inter"
            font.pixelSize: 13
        }

        // Right: drop-in extensions + system tray + clock.
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

            Row {
                spacing: 6
                anchors.verticalCenter: parent.verticalCenter
                Repeater {
                    model: tray.items
                    delegate: Item {
                        id: trayItem
                        required property var modelData
                        width: 22
                        height: 22

                        Image {
                            anchors.centerIn: parent
                            width: 18
                            height: 18
                            sourceSize.width: 18
                            sourceSize.height: 18
                            fillMode: Image.PreserveAspectFit
                            source: trayItem.modelData.icon || ""
                        }

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                            onClicked: function(mouse) {
                                const it = trayItem.modelData
                                if (mouse.button === Qt.MiddleButton) {
                                    it.secondaryActivate()
                                } else if (it.onlyMenu) {
                                    const p = trayItem.mapToItem(bar.contentItem, mouse.x, mouse.y)
                                    it.display(bar, p.x, p.y + trayItem.height)
                                } else {
                                    it.activate()
                                }
                            }
                        }
                    }
                }
            }

            Text {
                id: clockText
                anchors.verticalCenter: parent.verticalCenter
                color: "#e0e1dd"
                font.family: "Inter"
                font.pixelSize: 13
            }
        }
    }
}
