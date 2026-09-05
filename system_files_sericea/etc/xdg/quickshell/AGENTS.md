# Ryven bar (Quickshell) — instructions for AI agents and humans

This directory is the live Quickshell bar config. Edits here take effect
automatically: saving any `.qml` file reloads the bar within about a second
(systemd user units `quickshell-reload.path` → `quickshell-reload.service`
restart `quickshell.service`). No root, no rebuilds, no reboots — `/usr` is
read-only on this system and this user-writable copy
(`~/.config/quickshell`) is what actually runs.

## Layout

- `shell.qml` — entry point; instantiates `ryven/Bar.qml`
- `ryven/Bar.qml` — the bar itself (PanelWindow, 32 px: sway workspaces on
  the left, hint in the center, extensions + tray + clock on the right)
- `ryven/Extensions.qml` — loader: instantiates every `ryven/extensions/*.qml` in sorted order
- `ryven/extensions/` — drop-in widgets (`example-hello.qml.off` shows the shape; rename to `.qml` to enable)

## How to change the bar

- Small tweaks (text, colors, spacing, workspaces, clock): edit
  `ryven/Bar.qml` directly.
- New widgets: **prefer** adding `ryven/extensions/NN-name.qml` — no
  existing file changes, trivially reversible.
- Remove a widget: delete its extension file (or rename it to `.off`).

## Extension contract

- Root is an `Item` sized for the bar: height ≤ 22 px, width = implicit
  width of your content.
- Self-contained: own imports, own state, no references into `Bar.qml`.
- Colors — Ryven Navy palette, Qt literals are `#AARRGGBB` (alpha first):
  bar bg `#142032`, panel `#0d1b2a`/`#1b263b`, accent `#415a77`,
  muted `#778da9`, text `#e0e1dd`, urgent `#d98a8a`. Font: Inter, 13 px.
- A broken extension logs a warning and is skipped — it cannot kill the bar.

## Quickshell API notes (Fedora 44 package, Quickshell 0.2.x)

- Docs: https://quickshell.org — types: `ShellRoot`, `PanelWindow`,
  `Quickshell.Io` (`Process`), `Quickshell.Services.SystemTray` (the tray
  `Bar.qml` already uses), `UPower`.
- Only use imports that appear in the shipped files or that the 0.2 docs
  list; random Qt modules are not available.
- Talk to Sway with `swaymsg`: `swaymsg -t get_workspaces` (JSON snapshot),
  `swaymsg -t subscribe -m '["workspace","window"]'` (one JSON event per
  line — `Bar.qml` drives its refresh from this), `swaymsg <command>` to
  act. System stats come from /proc, /sys, or Quickshell services via
  `Quickshell.Io.Process`.
- `console.log`/`console.warn` land in `journalctl --user -u quickshell -f`.

## Verify your change

1. Save — watch the bar restart (auto-reload).
2. `journalctl --user -u quickshell -n 50` — no QML errors.
3. Manual restart: `ujust reload-bar`.
4. Broken beyond repair? Restore defaults:
   `cp -a /etc/xdg/quickshell/. ~/.config/quickshell/`
