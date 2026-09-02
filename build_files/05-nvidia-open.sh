#!/bin/bash
# OGC kernel from ghcr.io/opengamingcollective/kernel-packages-fedora:latest-fc44
# plus ublue akmods / akmods-extra / akmods-nvidia-open (ogc-44).
# Prebuilt kmod-* + *-kmod-common only. Never akmod-* (%post compiles as root).
# No kernel versionlock. No v4l2loopback.

set -ouex pipefail

OGC_IMAGE="ghcr.io/opengamingcollective/kernel-packages-fedora:latest-fc44"

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

dnf5 -y install jq skopeo

extract_ogc_kernel() {
  local dest=$1
  mkdir -p "${dest}" /tmp/ogc-oci
  skopeo copy --retry-times 3 "docker://${OGC_IMAGE}" "dir:/tmp/ogc-oci"
  local manifest=/tmp/ogc-oci/manifest.json
  if [[ ! -f ${manifest} ]]; then
    echo "OGC kernel OCI manifest missing" >&2
    ls -la /tmp/ogc-oci >&2
    exit 1
  fi
  local layer title digest blob
  while read -r layer; do
    title=$(jq -r '.annotations["org.opencontainers.image.title"] // empty' <<<"${layer}")
    digest=$(jq -r '.digest' <<<"${layer}")
    [[ -n ${title} && -n ${digest} ]] || continue
    if ! grep -qE '^(kernel-[0-9]|kernel-core-|kernel-devel-|kernel-devel-matched-|kernel-modules-|kernel-modules-core-|kernel-modules-extra-|kernel-tools)' <<<"${title}"; then
      continue
    fi
    blob=/tmp/ogc-oci/${digest#sha256:}
    if [[ ! -f ${blob} ]]; then
      echo "OGC blob missing for ${title} (${digest})" >&2
      exit 1
    fi
    echo "OGC kernel RPM: ${title}"
    if tar tf "${blob}" >/dev/null 2>&1; then
      tar xf "${blob}" -C "${dest}"
    else
      cp -a "${blob}" "${dest}/${title}"
    fi
  done < <(jq -c '.layers[]' "${manifest}")
}

extract_ogc_kernel /tmp/kernel-rpms

if ! compgen -G "/tmp/kernel-rpms/kernel-core-*.rpm" >/dev/null; then
  echo "OGC kernel-core RPM missing under /tmp/kernel-rpms" >&2
  find /tmp/kernel-rpms -type f >&2 || true
  exit 1
fi

for pkg in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-tools kernel-tools-libs; do
  if rpm -q "${pkg}" >/dev/null 2>&1; then
    rpm --erase "${pkg}" --nodeps
  fi
done
rm -rf /usr/lib/modules/*

dnf5 -y install \
  /tmp/kernel-rpms/kernel-[0-9]*.rpm \
  /tmp/kernel-rpms/kernel-core-*.rpm \
  /tmp/kernel-rpms/kernel-modules-*.rpm \
  /tmp/kernel-rpms/kernel-devel-*.rpm

KVER=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n1)

if [[ -f /etc/yum.repos.d/_copr_ublue-os-akmods.repo ]]; then
  sed -i 's@enabled=0@enabled=1@g' /etc/yum.repos.d/_copr_ublue-os-akmods.repo
fi
if compgen -G "/tmp/akmods-rpms/ublue-os/ublue-os-akmods-addons*.rpm" >/dev/null; then
  dnf5 -y install /tmp/akmods-rpms/ublue-os/ublue-os-akmods-addons*.rpm
elif compgen -G "/tmp/akmods-rpms/ublue-os/ublue-os-akmods*.rpm" >/dev/null; then
  dnf5 -y install /tmp/akmods-rpms/ublue-os/ublue-os-akmods*.rpm
fi

# Install prebuilt modules + their kmod-common userspace. Skip akmod-* sources.
install_kmod_bundle() {
  local -a rpms=()
  local f
  for f in "$@"; do
    [[ -f $f ]] || continue
    [[ ${f##*/} == akmod-* ]] && continue
    rpms+=("$f")
  done
  if ((${#rpms[@]} == 0)); then
    echo "No matching prebuilt kmod RPMs for: $*" >&2
    return 0
  fi
  rpm --install --nodeps "${rpms[@]}"
}

shopt -s nullglob
install_kmod_bundle \
  /tmp/akmods-rpms/kmods/kmod-xone*.rpm \
  /tmp/akmods-rpms/common/*xone*kmod-common*.rpm \
  /tmp/akmods-rpms/kmods/*xone*kmod-common*.rpm \
  /tmp/akmods-rpms/common/xone-kmod-common*.rpm \
  /tmp/akmods-rpms/kmods/kmod-xpadneo*.rpm \
  /tmp/akmods-rpms/common/*xpadneo*kmod-common*.rpm \
  /tmp/akmods-rpms/kmods/*xpadneo*kmod-common*.rpm \
  /tmp/akmods-rpms/kmods/kmod-openrazer*.rpm \
  /tmp/akmods-rpms/common/*openrazer*kmod-common*.rpm \
  /tmp/akmods-rpms/kmods/*openrazer*kmod-common*.rpm

install_kmod_bundle \
  /tmp/akmods-extra-rpms/kmods/kmod-*ryzen*smu*.rpm \
  /tmp/akmods-extra-rpms/extra/kmod-*ryzen*smu*.rpm \
  /tmp/akmods-extra-rpms/kmods/*ryzen*smu*kmod-common*.rpm \
  /tmp/akmods-extra-rpms/extra/*ryzen*smu*kmod-common*.rpm \
  /tmp/akmods-extra-rpms/kmods/kmod-*zenergy*.rpm \
  /tmp/akmods-extra-rpms/extra/kmod-*zenergy*.rpm \
  /tmp/akmods-extra-rpms/kmods/*zenergy*kmod-common*.rpm \
  /tmp/akmods-extra-rpms/extra/*zenergy*kmod-common*.rpm

if [[ -f /etc/yum.repos.d/_copr_ublue-os-akmods.repo ]]; then
  sed -i 's@enabled=1@enabled=0@g' /etc/yum.repos.d/_copr_ublue-os-akmods.repo
fi

AKMODNV_PATH=/tmp/akmods-nvidia-rpms
if [[ ! -f ${AKMODNV_PATH}/kmods/nvidia-vars ]]; then
  echo "akmods-nvidia-open:ogc-44 missing ${AKMODNV_PATH}/kmods/nvidia-vars" >&2
  find /tmp/akmods-nvidia-rpms -type f | head -80 >&2
  exit 1
fi

INSTALL_SH=""
if [[ -x ${AKMODNV_PATH}/ublue-os/nvidia-install.sh ]]; then
  INSTALL_SH=${AKMODNV_PATH}/ublue-os/nvidia-install.sh
elif [[ -f ${AKMODNV_PATH}/ublue-os/nvidia-install.sh ]]; then
  INSTALL_SH=${AKMODNV_PATH}/ublue-os/nvidia-install.sh
fi
if [[ -z ${INSTALL_SH} ]]; then
  INSTALL_SH=$(find /tmp/akmods-nvidia-rpms -name nvidia-install.sh -type f -print -quit)
fi
if [[ -z ${INSTALL_SH} ]]; then
  echo "nvidia-install.sh missing from akmods-nvidia-open:ogc-44" >&2
  find /tmp/akmods-nvidia-rpms -type f | head -80 >&2
  exit 1
fi

# kinoite variant so nvidia-install.sh can pull supergfxctl if present.
IMAGE_NAME=kinoite AKMODNV_PATH="${AKMODNV_PATH}" MULTILIB=1 \
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
