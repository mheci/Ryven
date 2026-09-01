#!/bin/bash
# Userspace from NVIDIA's Fedora 44 cuda repo (nvidia-open).
# Prebuilt open kmods from ublue-os/akmods-nvidia-open for this image kernel.
# DKMS cannot build against the ublue kernel: kernel-devel NVR is not in Fedora.

set -ouex pipefail

NVIDIA_REPO=cuda-fedora44-x86_64
KVER=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n1)
AKMODS_TAG="main-$(rpm -E %fedora)-${KVER}"

dnf5 -y install skopeo jq

skopeo copy --retry-times 3 \
  "docker://ghcr.io/ublue-os/akmods-nvidia-open:${AKMODS_TAG}" \
  dir:/tmp/akmods-nvidia-open

NVIDIA_TARGZ=$(jq -r '.layers[].digest' </tmp/akmods-nvidia-open/manifest.json | cut -d: -f2)
tar -xzf /tmp/akmods-nvidia-open/"${NVIDIA_TARGZ}" -C /tmp/
if [[ -d /tmp/rpms ]]; then
  mv /tmp/rpms /tmp/akmods-nvidia-rpms
fi

dnf5 -y install --enablerepo="${NVIDIA_REPO}" --exclude=kmod-nvidia-open-dkms nvidia-open

if [[ -x /tmp/akmods-nvidia-rpms/ublue-os/nvidia-install.sh ]]; then
  IMAGE_NAME=ryven AKMODNV_PATH="/tmp/akmods-nvidia-rpms" MULTILIB=0 \
    /tmp/akmods-nvidia-rpms/ublue-os/nvidia-install.sh
else
  dnf5 -y install /tmp/akmods-nvidia-rpms/kmods/kmod-nvidia-*.rpm
fi

rm -f /usr/share/vulkan/icd.d/nouveau_icd.*.json
depmod -a "${KVER}"

mkdir -p /usr/lib/bootc/kargs.d
cat >/usr/lib/bootc/kargs.d/00-nvidia.toml <<'EOF'
kargs = ["rd.driver.blacklist=nouveau", "modprobe.blacklist=nouveau", "nvidia-drm.modeset=1"]
EOF
