#!/bin/bash
# NVIDIA VA-API (NVDEC/NVENC wrapper) + Vulkan userspace from Fusion.
# Kernel modules come from ublue akmods-nvidia-open, not the CUDA repo.

set -ouex pipefail

dnf5 -y install \
  --enablerepo=rpmfusion-nonfree \
  --enablerepo=rpmfusion-nonfree-updates \
  --exclude='cuda*' \
  --exclude='*nvidia*cuda*' \
  libva-nvidia-driver.x86_64 \
  libva-nvidia-driver.i686 \
  nvidia-settings \
  vulkan-loader.x86_64 \
  vulkan-loader.i686 \
  vulkan-tools
