# Ryven — global agent instructions

You are on Ryven, an immutable (bootc/ostree) Fedora gaming desktop.
Three variants exist: `ryven` (KDE Plasma), `ryven-kunzite` (Hyprland),
`ryven-sericea` (Sway). Detect the variant with `echo $XDG_CURRENT_DESKTOP`.

## Immutable-system rules

- `/usr` and `/etc` are read-only image content. Never write there — changes
  do not persist and can break `bootc upgrade`.
- User configuration lives in `~/.config`, data in `~/.local/share`,
  helper binaries in `~/.local/bin`.
- For system-level operations use the preinstalled `ujust` recipes
  (`ujust --list` shows them). GUI package installs: `pkcon install <pkg>`.
  Everything else: flatpak, distrobox/podman, or `~/.local`.
- Never reboot or run `bootc switch/upgrade` without the user explicitly
  asking; updates stage in the background and wait.

## Already installed — do not reinstall

nodejs + npm, bun, deno, rustup, uv, mise, starship, zed, mpv, yazi,
opencode, firefox, zen, brave-origin, betterbird, steam + proton tweaks,
keepassxc, bitwarden, kdeconnect. Check with `command -v <tool>` first.

## Quickshell bar (ryven-kunzite, ryven-sericea)

The bar config is `~/.config/quickshell` — user-writable, auto-reloads on
every save, and has a drop-in extension system plus its own AGENTS.md with
the full contract. To customize it: `cd ~/.config/quickshell` (its AGENTS.md
loads automatically) or run `ujust customize-bar`.

## Verification

There is no test suite on this machine — runtime checks are the tests.
After changing a user service or the bar, check
`journalctl --user -u <unit> -n 50` for errors and confirm the visible
result before declaring the change done.
