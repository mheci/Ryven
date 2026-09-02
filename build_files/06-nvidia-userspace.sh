#!/bin/bash
# NVIDIA VA-API + Vulkan. Do not use terra-release-nvidia.
# libva-nvidia-driver: Fusion (not Terra nvidia). vulkan-*: Fedora.

set -ouex pipefail
# shellcheck source=repo-priority.sh
source /ctx/repo-priority.sh

dnf5 -y install \
  --enablerepo="${FUSION_REPOS}" \
  --exclude='cuda*' \
  --exclude='*nvidia*cuda*' \
  libva-nvidia-driver.x86_64 \
  libva-nvidia-driver.i686

install_priority vulkan-loader.x86_64 vulkan-loader.i686 vulkan-tools
# nvidia-settings: ublue nvidia-install.sh already pulls it; Fusion if missing.
if ! rpm -q nvidia-settings >/dev/null 2>&1; then
  dnf5 -y install --enablerepo="${FUSION_REPOS}" --exclude='cuda*' nvidia-settings
fi
