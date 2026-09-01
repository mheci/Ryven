#!/bin/bash
# NVIDIA userspace without CUDA toolkit. VA-API + settings.
# Kernel modules already installed by 05-nvidia-open.sh.

set -ouex pipefail

dnf5 -y install \
  --enablerepo=rpmfusion-nonfree \
  --enablerepo=rpmfusion-nonfree-updates \
  --exclude='cuda*' \
  --exclude='*nvidia*cuda*' \
  libva-nvidia-driver \
  nvidia-settings
