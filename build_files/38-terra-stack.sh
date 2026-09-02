#!/bin/bash
# Terra f44 Names (expanded): ghostty-tip, heroic-games-launcher, terra-gamescope, …
# gpu-screen-recorder is not on Terra f44; Fusion/Fedora then author COPR.

set -ouex pipefail
# shellcheck source=repo-priority.sh
source /ctx/repo-priority.sh
# shellcheck source=copr-helpers.sh
source /ctx/copr-helpers.sh

install_any ghostty-tip ghostty
install_priority \
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

install_priority \
  opencode-cli \
  rpcs3 \
  extest \
  vicinae \
  espanso-wayland

if ! install_priority gpu-screen-recorder; then
  copr_install_isolated "brycensranch/gpu-screen-recorder-git" gpu-screen-recorder
fi

install_priority \
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
