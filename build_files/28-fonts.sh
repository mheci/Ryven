#!/bin/bash
# Nerd Fonts (Terra if present), Open Sans, Adwaita, Droid, DejaVu, monospace.

set -ouex pipefail

dnf5 -y install --skip-unavailable --skip-broken \
  dejavu-sans-fonts \
  dejavu-sans-mono-fonts \
  dejavu-serif-fonts \
  google-droid-sans-fonts \
  google-droid-serif-fonts \
  google-droid-sans-mono-fonts \
  google-noto-sans-mono-fonts \
  google-noto-sans-fonts \
  rsms-inter-fonts \
  jetbrains-mono-fonts \
  mozilla-fira-mono-fonts \
  adwaita-fonts \
  adwaita-sans-fonts \
  adwaita-mono-fonts \
  google-opensans-fonts \
  google-crosextra-carlito-fonts

dnf5 -y install --enablerepo=terra --skip-unavailable --skip-broken \
  nerd-fonts \
  jetbrains-mono-nerd-fonts \
  nerd-fonts-jetbrains-mono \
  nerd-fonts-symbols \
  symbols-nerd-fonts \
  cleartype-fonts || true
