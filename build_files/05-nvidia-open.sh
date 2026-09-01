#!/bin/bash
# Open NVIDIA kmods for the ublue kernel from akmods-nvidia-open.
# The nvidia-open metapackage requires kmod-nvidia-open-dkms, which cannot
# build: Fedora does not publish kernel-devel for this NVR. Official CUDA
# repo remains on the image for userspace in a later commit.

set -ouex pipefail

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

if [[ ! -x /tmp/akmods-nvidia-rpms/ublue-os/nvidia-install.sh ]]; then
  echo "ublue nvidia-install.sh missing from akmods-nvidia-open:${AKMODS_TAG}" >&2
  find /tmp/akmods-nvidia-rpms -type f | head -50 >&2
  exit 1
fi

IMAGE_NAME=ryven AKMODNV_PATH="/tmp/akmods-nvidia-rpms" MULTILIB=0 \
  /tmp/akmods-nvidia-rpms/ublue-os/nvidia-install.sh

rm -f /usr/share/vulkan/icd.d/nouveau_icd.*.json
depmod -a "${KVER}"

mkdir -p /usr/lib/bootc/kargs.d
# Early KMS + module params from ArchWiki NVIDIA / Tips and tricks
# (DRM KMS, PowerMizer max, ReBAR, PAT, stream memops, preserve VRAM).
cat >/usr/lib/bootc/kargs.d/00-nvidia.toml <<'EOF'
kargs = [
  "rd.driver.blacklist=nouveau",
  "modprobe.blacklist=nouveau",
  "rd.driver.pre=nvidia",
  "nvidia-drm.modeset=1",
  "nvidia-drm.fbdev=1",
  "nvidia.NVreg_PreserveVideoMemoryAllocations=1",
  "nvidia.NVreg_TemporaryFilePath=/var/tmp",
  "nvidia.NVreg_EnableResizableBar=1",
  "nvidia.NVreg_EnablePCIeGen3=1",
  "nvidia.NVreg_UsePageAttributeTable=1",
  "nvidia.NVreg_EnableStreamMemOPs=1",
  "nvidia.NVreg_DynamicPowerManagement=0",
  "nvidia.NVreg_EnableGpuFirmware=1",
  "nvidia.NVreg_RegistryDwords=PerfLevelSrc=0x2222",
]
EOF
