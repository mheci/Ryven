---
name: ryven-quickshell-bar
description: Customize the Ryven Quickshell bar on ryven-kunzite (Hyprland) and ryven-sericea (Sway). Use when the user asks to change, extend, restyle, or add widgets/modules to the bar, panel, or status line, or mentions quickshell.
---

# Ryven Quickshell bar customization

The live bar config is `~/.config/quickshell` (seeded from the read-only
`/etc/xdg/quickshell`; re-seed with `ujust customize-bar`). That directory
has its own AGENTS.md with the full contract — read it first.

## Steps

1. Inspect the config: `ls -R ~/.config/quickshell`, then read
   `ryven/Bar.qml` and `ryven/Extensions.qml`.
2. New widget → create `~/.config/quickshell/ryven/extensions/NN-name.qml`.
   Root must be an Item ≤ 22 px tall, self-contained (own imports/state),
   colors in #AARRGGBB (alpha first), font Inter 13.
   Changing existing behavior → edit `ryven/Bar.qml` minimally instead.
3. Saving auto-reloads the bar within ~1 s (systemd user path unit). Watch
   what happens: `journalctl --user -u quickshell -f`.
4. Manual controls: `ujust reload-bar` (restart now),
   `systemctl --user status quickshell.service`.
5. Data sources: sericea uses `swaymsg -t get_workspaces` /
   `swaymsg -t subscribe -m` (JSON); kunzite uses `hyprctl -j <object>`
   (JSON) or the native `Quickshell.Hyprland` module. System stats come
   from /proc, /sys, or Quickshell services (UPower, SystemTray) via
   `Quickshell.Io.Process`.
6. Bar disappeared? `journalctl --user -u quickshell -n 50` shows the QML
   error. To restore defaults:
   `cp -a /etc/xdg/quickshell/. ~/.config/quickshell/`.

Docs: https://quickshell.org (QML API reference). Fedora 44 ships
Quickshell 0.2.x — only use imports/types that already appear in the
shipped files or that the docs list for 0.2.
