#!/usr/bin/env bash
# Basic retry helper for transient network failures
try() { for i in 1 2 3; do "$@" && return 0; echo "  retry $i/3 ($*)"; sleep 5; done; return 1; }
# Install default Ryven dark (Catppuccin Mocha) theme defaults, fontconfig.
set -euo pipefail
shopt -s nullglob

# Fontconfig defaults (Inter UI, JetBrains Mono, RGB subpixel, hintslight)
[ -f system_files/common/etc/fonts/local.conf ] && cp system_files/common/etc/fonts/local.conf /etc/fonts/local.conf
fc-cache -f 2>&1 || echo "(fc-cache failed; fonts will be cached at first login)"

# Default dconf/Gsettings for dark theme (applies in both DEs). Requires a writable HOME and may fail without dbus; non-fatal.
mkdir -p /root/.cache/dconf /root/.config/dconf
if command -v dconf &>/dev/null; then
    # Note: dconf requires dbus-daemon (machine-id + session bus); skip in container if bus unavailable.
    (dbus-run-session -- dconf write /org/gnome/desktop/interface/color-scheme "'prefer-dark'" 2>/dev/null && \
     dbus-run-session -- dconf write /org/gnome/desktop/interface/gtk-theme "'catppuccin-mocha-mauve-standard+default'" 2>/dev/null && \
     dbus-run-session -- dconf write /org/gnome/desktop/interface/icon-theme "'Papirus-Dark'" 2>/dev/null && \
     dbus-run-session -- dconf write /org/gnome/desktop/interface/cursor-theme "'Bibata-Modern-Ice'" 2>/dev/null && \
     dbus-run-session -- dconf write /org/gnome/desktop/interface/font-name "'Inter 10'" 2>/dev/null && \
     dbus-run-session -- dconf write /org/gnome/desktop/interface/monospace-font-name "'JetBrains Mono 10'" 2>/dev/null) \
        || echo "(dconf writes skipped in container; theme defaults applied via skel/gtkrc at login)"
fi

# Copy skel defaults to /etc/skel (skel is at /tmp/skel per Containerfile)
cp -r /tmp/skel/. /etc/skel/ 2>/dev/null || true

# Copy Plasma Login Manager config (KDE)
if [ "${IMAGE_VARIANT:-}" = "kde" ]; then
    for f in system_files/kde/usr/share/plasma/plasmalogin.conf.d/*.conf; do [ -f "$f" ] && cp "$f" /usr/share/plasma/plasmalogin.conf.d/; done
    for f in system_files/kde/usr/share/kwin/rules/*.rules; do [ -f "$f" ] && cp "$f" /usr/share/kwin/rules/; done
fi

# Copy Hyprland/quickshell/ryven-control defaults (wl)
if [ "${IMAGE_VARIANT:-}" = "wl" ]; then
    [ -d system_files/wl/usr/share/hypr/ryven-default ] && cp -r system_files/wl/usr/share/hypr/ryven-default /usr/share/hypr/
    [ -d system_files/wl/usr/share/quickshell/ryven ] && cp -r system_files/wl/usr/share/quickshell/ryven /usr/share/quickshell/
    [ -d system_files/wl/usr/lib/ryven-control ] && cp -r system_files/wl/usr/lib/ryven-control /usr/lib/
    for f in system_files/wl/usr/lib/systemd/system/greetd.service.d/*.conf; do [ -f "$f" ] && cp "$f" /usr/lib/systemd/system/greetd.service.d/; done
    [ -f system_files/wl/etc/greetd/config.toml ] && cp system_files/wl/etc/greetd/config.toml /etc/greetd/
fi

echo "Themes and skel applied."
