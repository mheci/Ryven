#!/bin/bash
# Core Fedora fonts, then Terra Nerd Fonts and ClearType.

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
  mozilla-fira-mono-fonts \
  adwaita-fonts \
  google-opensans-fonts \
  google-crosextra-carlito-fonts

dnf5 -y install --enablerepo=terra nerd-fonts cleartype-fonts
