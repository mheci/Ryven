#!/bin/bash
# OGC kernel + nvidia-open kmods from ublue akmods (not NVIDIA CUDA repo).
# Tags: ghcr.io/ublue-os/akmods:ogc-44 and akmods-nvidia-open:ogc-44.

set -ouex pipefail

FEDORA_RELEASE="$(rpm -E %fedora)"
AKMODS_FLAVOR=ogc
AKMODS_TAG="${AKMODS_FLAVOR}-${FEDORA_RELEASE}"

extract_akmods() {
  local image=$1
  local dest=$2
  rm -rf "${dest}" /tmp/akmods-oci /tmp/rpms /tmp/kernel-rpms
  mkdir -p /tmp/akmods-oci "${dest}"
  skopeo copy --retry-times 3 "docker://${image}" dir:/tmp/akmods-oci
  local layer
  layer=$(jq -r '.layers[-1].digest' </tmp/akmods-oci/manifest.json | cut -d: -f2)
  tar -xzf /tmp/akmods-oci/"${layer}" -C /tmp/
  if [[ -d /tmp/rpms ]]; then
    cp -a /tmp/rpms/. "${dest}/"
  fi
  if [[ -d /tmp/kernel-rpms ]]; then
    mkdir -p "${dest}/kernel-rpms"
    cp -a /tmp/kernel-rpms/. "${dest}/kernel-rpms/"
  fi
}

dnf5 -y install skopeo jq

# Bypass kernel-install hooks that expect a booted ostree (Bazzite pattern).
if [[ -d /usr/lib/kernel/install.d ]]; then
  pushd /usr/lib/kernel/install.d >/dev/null
  for f in 05-rpmostree.install 50-dracut.install; do
    if [[ -e $f ]]; then
      mv "$f" "${f}.bak"
      printf '%s\n' '#!/bin/sh' 'exit 0' >"$f"
      chmod +x "$f"
    fi
  done
  popd >/dev/null
fi

extract_akmods "ghcr.io/ublue-os/akmods:${AKMODS_TAG}" /tmp/akmods-ogc

# Replace Fedora/ublue-main kernel with OGC kernel RPMs from the akmods image.
if compgen -G "/tmp/akmods-ogc/kernel-rpms/kernel-core-*.rpm" >/dev/null; then
  for pkg in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-tools kernel-tools-libs; do
    rpm --erase "${pkg}" --nodeps || true
  done
  dnf5 -y install \
    /tmp/akmods-ogc/kernel-rpms/kernel-[0-9]*.rpm \
    /tmp/akmods-ogc/kernel-rpms/kernel-core-*.rpm \
    /tmp/akmods-ogc/kernel-rpms/kernel-modules-*.rpm \
    /tmp/akmods-ogc/kernel-rpms/kernel-devel-*.rpm || \
  dnf5 -y install /tmp/akmods-ogc/kernel-rpms/kernel-*.rpm
fi

KVER=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n1)

# Common signed kmods that are useful on a gaming desktop.
dnf5 -y install /tmp/akmods-ogc/ublue-os/ublue-os-akmods*.rpm || true
shopt -s nullglob
COMMON=(/tmp/akmods-ogc/kmods/*v4l2loopback*.rpm /tmp/akmods-ogc/kmods/*xone*.rpm /tmp/akmods-ogc/kmods/*xpadneo*.rpm /tmp/akmods-ogc/kmods/*openrazer*.rpm)
if ((${#COMMON[@]})); then
  dnf5 -y install "${COMMON[@]}" || true
fi

extract_akmods "ghcr.io/ublue-os/akmods-extra:${AKMODS_TAG}" /tmp/akmods-extra || true
EXTRA=(/tmp/akmods-extra/kmods/*ryzen*smu*.rpm /tmp/akmods-extra/kmods/*zenergy*.rpm)
if ((${#EXTRA[@]})); then
  dnf5 -y install "${EXTRA[@]}" || true
fi

extract_akmods "ghcr.io/ublue-os/akmods-nvidia-open:${AKMODS_TAG}" /tmp/akmods-nvidia-rpms

INSTALL_SH=$(find /tmp/akmods-nvidia-rpms -name nvidia-install.sh -type f -print -quit)
if [[ -z ${INSTALL_SH} ]]; then
  echo "ublue nvidia-install.sh missing from akmods-nvidia-open:${AKMODS_TAG}" >&2
  find /tmp/akmods-nvidia-rpms -type f | head -80 >&2
  exit 1
fi

AKMODNV_PATH=$(dirname "$(dirname "${INSTALL_SH}")")
if [[ -d /tmp/akmods-nvidia-rpms/ublue-os ]]; then
  AKMODNV_PATH=/tmp/akmods-nvidia-rpms
fi

IMAGE_NAME=ryven AKMODNV_PATH="${AKMODNV_PATH}" MULTILIB=1 \
  bash "${INSTALL_SH}"

rm -f /usr/share/vulkan/icd.d/nouveau_icd.*.json
if [[ -e /usr/lib64/libnvidia-ml.so.1 ]]; then
  ln -sf libnvidia-ml.so.1 /usr/lib64/libnvidia-ml.so
fi
depmod -a "${KVER}"

if [[ -d /usr/lib/kernel/install.d ]]; then
  pushd /usr/lib/kernel/install.d >/dev/null
  for f in 05-rpmostree.install 50-dracut.install; do
    if [[ -e ${f}.bak ]]; then
      mv -f "${f}.bak" "$f"
    fi
  done
  popd >/dev/null
fi

mkdir -p /usr/lib/bootc/kargs.d
cat >/usr/lib/bootc/kargs.d/00-nvidia.toml <<'EOF'
kargs = [
  "rd.driver.blacklist=nouveau",
  "modprobe.blacklist=nouveau",
  "rd.driver.pre=nvidia",
  "nvidia-drm.modeset=1",
  "nvidia-drm.fbdev=1",
  "initcall_blacklist=simpledrm_platform_driver_init",
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
