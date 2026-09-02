#!/bin/bash
# OGC kernel + nvidia-open kmods from ublue akmods bind-mounts (Containerfile COPY --from).
# No kernel versionlock. No v4l2loopback.

set -ouex pipefail

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

if ! compgen -G "/tmp/kernel-rpms/kernel-core-*.rpm" >/dev/null; then
  echo "OGC kernel RPMs missing under /tmp/kernel-rpms" >&2
  ls -la /tmp/kernel-rpms >&2 || true
  exit 1
fi

for pkg in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-tools kernel-tools-libs; do
  if rpm -q "${pkg}" >/dev/null 2>&1; then
    rpm --erase "${pkg}" --nodeps
  fi
done
rm -rf /usr/lib/modules/*

dnf5 -y install /tmp/kernel-rpms/kernel*.rpm

KVER=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n1)

if compgen -G "/tmp/akmods-rpms/ublue-os/ublue-os-akmods*.rpm" >/dev/null; then
  dnf5 -y install /tmp/akmods-rpms/ublue-os/ublue-os-akmods*.rpm
fi

# Prebuilt kmod-* RPMs only. Never install akmod-* (their %post compiles as root).
shopt -s nullglob
COMMON=(/tmp/akmods-rpms/kmods/kmod-xone*.rpm /tmp/akmods-rpms/kmods/kmod-xpadneo*.rpm /tmp/akmods-rpms/kmods/kmod-openrazer*.rpm)
if ((${#COMMON[@]})); then
  rpm --install --nodeps "${COMMON[@]}"
fi

EXTRA=(/tmp/akmods-extra-src/rpms/kmods/kmod-*ryzen*smu*.rpm /tmp/akmods-extra-src/rpms/extra/kmod-*ryzen*smu*.rpm /tmp/akmods-extra-src/rpms/kmods/kmod-*zenergy*.rpm /tmp/akmods-extra-src/rpms/extra/kmod-*zenergy*.rpm)
if ((${#EXTRA[@]})); then
  rpm --install --nodeps "${EXTRA[@]}"
fi

INSTALL_SH=$(find /tmp/akmods-nvidia-src -name nvidia-install.sh -type f -print -quit)
if [[ -z ${INSTALL_SH} ]]; then
  echo "ublue nvidia-install.sh missing from akmods-nvidia-open:ogc-44" >&2
  find /tmp/akmods-nvidia-src -type f | head -80 >&2
  exit 1
fi

AKMODNV_PATH=$(dirname "$(dirname "${INSTALL_SH}")")
if [[ -d /tmp/akmods-nvidia-src/rpms ]]; then
  AKMODNV_PATH=/tmp/akmods-nvidia-src
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
