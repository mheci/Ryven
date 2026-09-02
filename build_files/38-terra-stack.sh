#!/bin/bash
# Terra apps, games, tuners, themes. Repos stay disabled on the image (04).
# Skip: terra-nvidia, other DEs, uutils-coreutils-replace (GNU coreutils),
# devcontainer (Docker). Prefer bpftune-gaming over bpftune (Conflicts).
# Prefer terra-gamescope over Fedora gamescope (Conflicts).
# Do not change the default Plasma look-and-feel (org.ryven.desktop).

set -ouex pipefail

TERRA=(--enablerepo=terra,terra-multimedia)

dnf5 -y install --skip-unavailable --skip-broken "${TERRA[@]}" \
  ghostty \
  opencode-cli \
  opencode \
  t3code \
  \
  heroic-games-launcher \
  protonplus \
  rpcs3 \
  opengamepadui \
  terra-gamescope \
  vulkan-low-latency-layer \
  \
  ananicy-cpp \
  cachyos-ananicy-rules \
  android-udev-rules \
  extest \
  \
  bpftune-gaming \
  lact \
  vicinae \
  espanso-wayland \
  \
  bibata-cursor-theme \
  breeze-plus-icon-theme \
  darkly \
  fluent-icon-theme \
  fluent-kde-theme \
  klassy \
  lightly-qt5 \
  lightly-qt6 \
  tela-icon-theme \
  \
  gpu-screen-recorder \
  gpu-screen-recorder-ui || true

# Gaming network tuner; do not enable if cardwire is the GPU BPF path.
# Install only; user can start bpftune.service.
# ananicy-cpp: optional auto-nice for games.
systemctl enable ananicy-cpp.service || true
