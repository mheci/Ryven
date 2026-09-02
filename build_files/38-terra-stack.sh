#!/bin/bash
# Terra apps, games, tuners, themes.
# Nightlies: t3code-nightly (mpv/scx are in 14/16).
# Enable bpftune-gaming and ananicy-cpp with CachyOS rules.

set -ouex pipefail

TERRA=(--enablerepo=terra,terra-multimedia)

dnf5 -y install "${TERRA[@]}" \
  ghostty \
  t3code-nightly \
  heroic-games-launcher \
  protonplus \
  terra-gamescope \
  vulkan-low-latency-layer \
  ananicy-cpp \
  cachyos-ananicy-rules \
  android-udev-rules \
  bpftune-gaming \
  lact

dnf5 -y install "${TERRA[@]}" \
  opencode-cli \
  rpcs3 \
  extest \
  vicinae \
  espanso-wayland \
  gpu-screen-recorder

dnf5 -y install "${TERRA[@]}" \
  bibata-cursor-theme \
  klassy \
  tela-icon-theme

if [[ -f /usr/lib/systemd/system/bpftune.service ]]; then
  systemctl enable bpftune.service
else
  echo "bpftune-gaming missing bpftune.service" >&2
  rpm -ql bpftune-gaming | head -40 >&2
  exit 1
fi

systemctl enable ananicy-cpp.service
