#!/bin/bash
# Fedora fonts that exist on F44. Terra: cleartype-fonts (Name: %{fontname}-fonts).

set -ouex pipefail
# shellcheck source=repo-priority.sh
source /ctx/repo-priority.sh

dnf5 -y install \
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
  adwaita-sans-fonts \
  adwaita-mono-fonts \
  google-crosextra-carlito-fonts

install_priority cleartype-fonts
