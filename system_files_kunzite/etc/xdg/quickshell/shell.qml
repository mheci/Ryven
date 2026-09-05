// Ryven-Kunzite bar entry (Hyprland). Quickshell resolves its config from
// ~/.config/quickshell first (seeded from /etc/skel, or on demand with
// `ujust customize-bar`), then falls back to this /etc/xdg copy. The bar
// itself lives in ryven/Bar.qml; drop-in widgets are loaded from
// ryven/extensions/*.qml. AI agents: read AGENTS.md next to this file.
import QtQuick
import Quickshell
import "ryven"

ShellRoot {
    Bar {}
}
