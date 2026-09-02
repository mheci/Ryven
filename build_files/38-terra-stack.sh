#!/bin/bash
# Terra f44 names verified against terrapkg/packages branch f44.
# Nightlies: t3code-nightly, ghostty-tip. No cardwire. No gpu-screen-recorder (not in f44).
# helium-browser-bin is not a Terra f44 Name.

set -ouex pipefail

TERRA=(--enablerepo=terra,terra-multimedia)

dnf5 -y install "${TERRA[@]}" \
  ghostty-tip \
  t3code-nightly \
  heroic-games-launcher \
  protonplus \
  terra-gamescope \
  vulkan-low-latency-layer \
  ananicy-cpp \
  cachyos-ananicy-rules \
  android-udev-rules \
  bpftune-gaming \
  lact \
  darkly

dnf5 -y install "${TERRA[@]}" \
  opencode-cli \
  rpcs3 \
  extest \
  vicinae \
  espanso-wayland

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
