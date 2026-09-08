#!/usr/bin/env bash
# Basic retry helper for transient network failures
try() { for i in 1 2 3; do "$@" && return 0; echo "  retry $i/3 ($*)"; sleep 5; done; return 1; }
# Install default Ryven dark (Catppuccin Mocha) theme defaults, fontconfig.
set -euo pipefail
shopt -s nullglob

# Fontconfig defaults (Inter UI, JetBrains Mono, RGB subpixel, hintslight)
cp system_files/common/etc/fonts/local.conf /etc/fonts/local.conf
fc-cache -f

# Default dconf/Gsettings for dark theme (applies in both DEs)
if command -v dconf &>/dev/null; then
    dconf write /org/gnome/desktop/interface/color-scheme "'prefer-dark'"
    dconf write /org/gnome/desktop/interface/gtk-theme "'catppuccin-mocha-mauve-standard+default'"
    dconf write /org/gnome/desktop/interface/icon-theme "'Papirus-Dark'"
    dconf write /org/gnome/desktop/interface/cursor-theme "'Bibata-Modern-Ice'"
    dconf write /org/gnome/desktop/interface/font-name "'Inter 10'"
    dconf write /org/gnome/desktop/interface/monospace-font-name "'JetBrains Mono 10'"
fi

# Copy skel defaults to /etc/skel
cp -r skel/. /etc/skel/

# Copy Plasma Login Manager config (KDE)
if [ "${IMAGE_VARIANT:-}" = "kde" ]; then
    cp system_files/kde/usr/share/plasma/plasmalogin.conf.d/*.conf /usr/share/plasma/plasmalogin.conf.d/
    cp system_files/kde/usr/share/kwin/rules/*.rules /usr/share/kwin/rules/
fi

# Copy Hyprland/quickshell/ryven-control defaults (wl)
if [ "${IMAGE_VARIANT:-}" = "wl" ]; then
    cp -r system_files/wl/usr/share/hypr/ryven-default /usr/share/hypr/
    cp -r system_files/wl/usr/share/quickshell/ryven /usr/share/quickshell/
    cp -r system_files/wl/usr/lib/ryven-control /usr/lib/
    cp system_files/wl/usr/lib/systemd/system/greetd.service.d/*.conf /usr/lib/systemd/system/greetd.service.d/
    cp system_files/wl/etc/greetd/config.toml /etc/greetd/
fi

echo "Themes and skel applied."
