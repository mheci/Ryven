#!/usr/bin/env bash
# Basic retry helper for transient network failures
try() { for i in 1 2 3; do "$@" && return 0; echo "  retry $i/3 ($*)"; sleep 5; done; return 1; }
# Configure flatpak: remove Fedora flatpak repo, enable Flathub, install Bazaar + Flatseal,
# apply global host theme overrides, install matching NVIDIA GL extensions.
set -euo pipefail
shopt -s nullglob

echo "Configuring flatpak..."
dnf5 install -y --skip-unavailable flatpak flatpak-builder

# Remove Fedora Flatpak repos
flatpak remote-delete fedora 2>/dev/null || true
flatpak remote-delete fedora-testing 2>/dev/null || true

# Add Flathub system-wide
flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# Apply global overrides so all flatpaks inherit host theme/fonts/cursor
mkdir -p /etc/flatpak/overrides
[ -f system_files/common/etc/flatpak/overrides/global ] && cp system_files/common/etc/flatpak/overrides/global /etc/flatpak/overrides/global

echo "Installing Bazaar + Flatseal..."
flatpak install -y --system flathub io.github.kolunmi.Bazaar com.github.tchx84.Flatseal 2>/dev/null || \
    echo "WARNING: Flatpak Bazaar/Flatseal install skipped (network or remote issue)"

# Install NVIDIA GL/GL32 extensions matching our driver version
NVIDIA_VERSION="$(rpm -q nvidia-driver --queryformat '%{VERSION}' | cut -d- -f1 | tr '.' '-')"
echo "Installing flatpak NVIDIA GL extensions for driver ${NVIDIA_VERSION}..."
flatpak install -y --system flathub \
    "org.freedesktop.Platform.GL.nvidia-${NVIDIA_VERSION}" \
    "org.freedesktop.Platform.GL32.nvidia-${NVIDIA_VERSION}" || \
    echo "NOTE: NVIDIA GL extension install skipped; will be resolved at first update if driver version mismatch."

echo "Flatpak configured."
