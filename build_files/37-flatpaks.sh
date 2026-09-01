#!/bin/bash
# Explicit system Flatpaks: Flatseal, Warehouse, Gear Lever, Bazaar.

set -ouex pipefail

dnf5 -y install --skip-unavailable flatpak || true
command -v flatpak >/dev/null || exit 0

flatpak remote-add --if-not-exists --system flathub \
  https://dl.flathub.org/repo/flathub.flatpakrepo || true

flatpak install --system --noninteractive --or-update flathub \
  com.github.tchx84.Flatseal \
  io.github.flattool.Warehouse \
  it.mijorus.gearlever \
  io.github.kolunmi.Bazaar || true
