#!/bin/bash
# Fedora fonts that exist on F44 (CI 33632168916: mozilla-fira-mono-fonts,
# adwaita-fonts, google-opensans-fonts are missing). Inter Regular is default.
# Terra: cleartype-fonts (anda/fonts/cleartype). nerd-fonts is not a Terra Name.

set -ouex pipefail

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

dnf5 -y install --enablerepo=terra cleartype-fonts
