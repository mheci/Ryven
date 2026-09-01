#!/bin/bash
# NVIDIA open kernel modules from the official Fedora 44 CUDA repo.
# nvidia-open pulls kmod-nvidia-open-dkms; build against the image kernel,
# not the GitHub runner's uname -r.

set -ouex pipefail

NVIDIA_REPO=cuda-fedora44-x86_64
KVER=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n1)

dnf5 -y install --enablerepo="${NVIDIA_REPO}" \
  kernel-devel-matched \
  kernel-headers

dnf5 -y install --enablerepo="${NVIDIA_REPO}" nvidia-open

if command -v dkms >/dev/null; then
  dkms autoinstall -k "${KVER}"
fi

depmod -a "${KVER}"

mkdir -p /usr/lib/bootc/kargs.d
cat >/usr/lib/bootc/kargs.d/00-nvidia.toml <<'EOF'
kargs = ["rd.driver.blacklist=nouveau", "modprobe.blacklist=nouveau", "nvidia-drm.modeset=1"]
EOF
