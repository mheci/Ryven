#!/bin/bash
# Ryven image compose. Fedora 44 Kinoite + ublue ogc-44 akmods + OGC kernel.
# Package source priority: official vendor/dev repos, Terra f44, RPM Fusion, Fedora.

set -ouex pipefail

cp -avf "/ctx/system_files"/. /

# Package source priority (highest first):
#   1. Official vendor/dev repos already on disk (Brave, mise, OpenRazer, …)
#   2. Terra f44 (terra, terra-extras, terra-multimedia, terra-mesa)
#   3. RPM Fusion free/nonfree (+ updates)
#   4. Fedora
#
# Names must match a real NEVRA. Terra Names were checked against
# terrapkg/packages branch f44. Subpackages (openrazer-daemon) are valid
# even when the spec Name: is the parent.

TERRA_REPOS="terra,terra-multimedia,terra-mesa"
FUSION_REPOS="rpmfusion-free,rpmfusion-free-updates,rpmfusion-nonfree,rpmfusion-nonfree-updates"

# install_priority [--official-repo=ID] PKG...
# Each name is resolved independently so Terra-only and Fusion/Fedora-only
# packages in one call do not fail the whole transaction.
install_priority() {
  local official=()
  local pkg
  while [[ ${1-} == --official-repo=* ]]; do
    official+=(--enablerepo="${1#--official-repo=}")
    shift
  done
  for pkg in "$@"; do
    if rpm -q "${pkg}" >/dev/null 2>&1; then
      continue
    fi
    if ((${#official[@]})) && dnf5 -y install "${official[@]}" "${pkg}"; then
      continue
    fi
    if dnf5 -y install --enablerepo="${TERRA_REPOS}" "${pkg}"; then
      continue
    fi
    if dnf5 -y install --enablerepo="${FUSION_REPOS}" "${pkg}"; then
      continue
    fi
    if dnf5 -y install "${pkg}"; then
      continue
    fi
    echo "No NEVRA for ${pkg} in official/Terra/Fusion/Fedora" >&2
    return 1
  done
  return 0
}

# Try each name in order until one installs.
install_any() {
  local name
  for name in "$@"; do
    if install_priority "${name}"; then
      return 0
    fi
  done
  echo "No provider for: $*" >&2
  return 1
}

swap_ffmpeg_priority() {
  if rpm -q ffmpeg >/dev/null 2>&1; then
    return 0
  fi
  if rpm -q ffmpeg-free >/dev/null 2>&1; then
    if dnf5 -y swap --enablerepo="${TERRA_REPOS}" --allowerasing ffmpeg-free ffmpeg; then
      return 0
    fi
    if dnf5 -y swap --enablerepo="${FUSION_REPOS}" --allowerasing ffmpeg-free ffmpeg; then
      return 0
    fi
  fi
  install_priority ffmpeg
}

# Enable a COPR only for the listed packages, then disable it.

copr_install_isolated() {
  local copr=$1
  shift
  dnf5 -y copr enable "${copr}"
  dnf5 -y install "$@"
  dnf5 -y copr disable "${copr}"
}

### RPM Fusion metadata

FEDORA_RELEASE=44

dnf5 -y install \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_RELEASE}.noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_RELEASE}.noarch.rpm"

### Terra f44 metadata (no terra-release-nvidia)

FEDORA_RELEASE=44

dnf5 -y install --nogpgcheck \
  --repofrompath "terra,https://repos.fyralabs.com/terra${FEDORA_RELEASE}" \
  terra-release

dnf5 -y install --enablerepo=terra \
  terra-release-extras \
  terra-release-mesa \
  terra-release-multimedia

### Disable third-party repos on the running image

shopt -s nullglob
for repo in /etc/yum.repos.d/rpmfusion*.repo \
            /etc/yum.repos.d/*terra*.repo; do
  sed -i 's/^enabled=1/enabled=0/' "${repo}"
done

### OGC kernel + ublue ogc-44 kmods

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

### NVIDIA VA-API / Vulkan userspace

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

### Secure Boot / TPM tooling

dnf5 -y install \
  just \
  mokutil \
  shim \
  efibootmgr \
  cryptsetup \
  clevis \
  clevis-luks \
  clevis-dracut \
  tpm2-tools

### chrony

dnf5 -y install chrony

systemctl enable chronyd.service
systemctl disable systemd-timesyncd.service 2>/dev/null || true
systemctl mask systemd-timesyncd.service 2>/dev/null || true

### Rootless Podman

dnf5 -y install podman podman-compose

if rpm -q docker-ce >/dev/null 2>&1 || rpm -q docker >/dev/null 2>&1; then
  echo "docker RPM must not be present" >&2
  exit 1
fi

# Socket for rootless/user workflows; no docker.socket.
systemctl enable podman.socket

### firewalld; sshd disabled

dnf5 -y install firewalld

systemctl enable firewalld.service
systemctl disable sshd.service 2>/dev/null || true
systemctl mask sshd.service 2>/dev/null || true

### git, gh, Git Credential Manager

dnf5 -y install git gh git-credential-libsecret

copr_install_isolated "vdanielmo/git-credential-manager" git-credential-manager

### mise, bun-bin, deno

if ! dnf5 -y install mise; then
  dnf5 -y config-manager addrepo --overwrite --from-repofile=https://mise.jdx.dev/rpm/mise.repo
  dnf5 -y install mise
  shopt -s nullglob
  for repo in /etc/yum.repos.d/*mise*.repo; do
    sed -i 's/^enabled=1/enabled=0/' "${repo}"
  done
fi

install_priority bun-bin
install_any rust-deno deno

### zed

install_priority zed

### mpv, yt-dlp, ffmpeg

install_priority mpv yt-dlp-git python-yt-dlp-ejs
swap_ffmpeg_priority

### Steam

install_priority steam

### scx-scheds / scx-tools

install_priority scx-scheds scx-tools

mkdir -p /etc
cat >/etc/scx_loader.toml <<'EOF'
default_sched = "scx_lavd"
default_mode = "Gaming"

[scheds.scx_lavd]
auto_mode = ["--performance"]
gaming_mode = ["--performance"]
lowlatency_mode = ["--performance"]
powersave_mode = ["--performance"]
EOF

mkdir -p /etc/scx_loader
ln -sfn /etc/scx_loader.toml /etc/scx_loader/config.toml

mkdir -p /etc/default
if [[ ! -f /etc/default/scx ]]; then
  printf 'SCX_SCHEDULER=scx_lavd\nSCX_FLAGS=--performance\n' >/etc/default/scx
fi

if [[ ! -f /usr/lib/systemd/system/scx_loader.service ]]; then
  echo "scx-tools did not ship scx_loader.service" >&2
  rpm -ql scx-tools | head -80 >&2
  exit 1
fi
systemctl enable scx_loader.service

### faugus-launcher

install_priority faugus-launcher

### Firefox RPM

dnf5 -y install firefox

if command -v flatpak >/dev/null 2>&1; then
  flatpak uninstall --system -y org.mozilla.firefox || true
fi

### Zen Browser

if ! install_any zen-browser; then
  copr_install_isolated "sneexy/zen-browser" zen-browser
fi

### Brave

cat >/etc/yum.repos.d/brave-browser.repo <<'EOF'
[brave-browser]
name=Brave Browser
baseurl=https://brave-browser-rpm-release.s3.brave.com/$basearch
enabled=0
gpgcheck=1
gpgkey=https://brave-browser-rpm-release.s3.brave.com/brave-core.asc
EOF

dnf5 -y install --enablerepo=brave-browser brave-origin

### Helium

install_any helium-browser-bin helium-browser

### Codecs, Mesa, thumbnails

if ! dnf5 -y distro-sync --enablerepo="${TERRA_REPOS}" \
  mesa-dri-drivers \
  mesa-va-drivers \
  mesa-vulkan-drivers \
  mesa-libGL \
  mesa-libEGL \
  mesa-libgbm \
  mesa-filesystem \
  mesa-dri-drivers.i686 \
  mesa-va-drivers.i686 \
  mesa-vulkan-drivers.i686 \
  mesa-libGL.i686 \
  mesa-libEGL.i686 \
  mesa-libgbm.i686; then
  echo "Terra Mesa distro-sync failed (NVIDIA userspace conflict). Keeping current Mesa." >&2
fi

swap_ffmpeg_priority

install_priority \
  libva \
  libva-utils \
  libvdpau \
  vdpauinfo \
  gstreamer1-plugin-libav \
  gstreamer1-plugin-openh264 \
  gstreamer1-vaapi \
  mozilla-openh264 \
  dav1d \
  aom \
  svt-av1 \
  lame \
  opus \
  ffmpegthumbnailer

if ! rpm -q libva-nvidia-driver >/dev/null 2>&1; then
  dnf5 -y install --enablerepo="${FUSION_REPOS}" \
    libva-nvidia-driver.x86_64 libva-nvidia-driver.i686
fi

install_priority \
  intel-media-driver \
  libva-intel-driver \
  gstreamer1-plugins-ugly \
  x264 \
  totem-video-thumbnailer \
  kdegraphics-thumbnailers \
  icoextract-thumbnailer

install_any python3-icoextract

dnf5 -y install --enablerepo=rpmfusion-free --enablerepo="${FUSION_REPOS}" rpmfusion-free-release-tainted
dnf5 -y install --enablerepo=rpmfusion-free-tainted libdvdcss
shopt -s nullglob
for repo in /etc/yum.repos.d/*tainted*.repo; do
  sed -i 's/^enabled=1/enabled=0/' "${repo}"
done

### zswap on, zram off

if rpm -q zram-generator-defaults >/dev/null 2>&1 || rpm -q zram-generator >/dev/null 2>&1; then
  dnf5 -y remove zram-generator-defaults zram-generator
fi
mkdir -p /usr/lib/systemd /etc/systemd/system
printf '%s\n' '# Ryven: zram disabled. Compressed RAM is zswap (see kargs.d/10-zswap.toml).' \
  >/usr/lib/systemd/zram-generator.conf
ln -sfn /dev/null /etc/systemd/system/systemd-zram-setup@zram0.service
systemctl mask systemd-zram-setup@zram0.service

### Plasma Login Manager

dnf5 -y install plasma-login-manager kcm-plasmalogin
systemctl enable --force plasmalogin.service
if [[ -f /usr/lib/systemd/system/sddm.service ]] || systemctl list-unit-files sddm.service >/dev/null 2>&1; then
  systemctl disable sddm.service
  systemctl mask sddm.service
fi

### greenboot

dnf5 -y install greenboot greenboot-default-health-checks

enabled=0
shopt -s nullglob
for unit in /usr/lib/systemd/system/greenboot*.service \
            /usr/lib/systemd/system/redboot*.service; do
  systemctl enable "$(basename "${unit}")"
  enabled=1
done
if [[ ${enabled} -eq 0 ]]; then
  echo "greenboot installed but no units under /usr/lib/systemd/system" >&2
  rpm -ql greenboot | head -40 >&2
  exit 1
fi

### sudo-rs

dnf5 -y install sudo-rs

### fonts

dnf5 -y install \
  dejavu-sans-fonts \
  dejavu-sans-mono-fonts \
  dejavu-serif-fonts \
  google-droid-sans-fonts \
  google-droid-serif-fonts \
  google-droid-sans-mono-fonts \
  google-noto-sans-mono-fonts \
  google-noto-sans-fonts \
  rsms-inter-fonts \
  jetbrains-mono-fonts \
  adwaita-sans-fonts \
  adwaita-mono-fonts \
  google-crosextra-carlito-fonts

install_priority cleartype-fonts

### Ryven branding

if [[ -f /usr/lib/os-release ]]; then
  sed -i \
    -e 's/^NAME=.*/NAME="Ryven"/' \
    -e 's/^PRETTY_NAME=.*/PRETTY_NAME="Ryven (Fedora Kinoite)"/' \
    /usr/lib/os-release
  if grep -q '^IMAGE_ID=' /usr/lib/os-release; then
    sed -i 's/^IMAGE_ID=.*/IMAGE_ID="ryven"/' /usr/lib/os-release
  else
    echo 'IMAGE_ID="ryven"' >>/usr/lib/os-release
  fi
fi

mkdir -p /etc/default/grub.d
cat >/etc/default/grub.d/50-ryven.cfg <<'EOF'
GRUB_DISTRIBUTOR="Ryven"
EOF

if [[ -d /usr/share/plymouth/themes/spinner && -f /usr/share/pixmaps/ryven.png ]]; then
  cp -f /usr/share/pixmaps/ryven.png /usr/share/plymouth/themes/spinner/watermark.png
fi

if [[ -d /usr/share/plasma/look-and-feel/org.ryven.desktop ]]; then
  mkdir -p /etc/xdg
  if [[ -x /usr/libexec/plasma-set-default-lookandfeel ]]; then
    /usr/libexec/plasma-set-default-lookandfeel org.ryven.desktop
  fi
fi

### ScopeBuddy

install_priority jq ScopeBuddy

if command -v scopebuddy >/dev/null && [[ ! -e /usr/bin/scb ]]; then
  ln -sf scopebuddy /usr/bin/scb
fi

### bees

install_priority bees

mkdir -p /usr/lib/systemd/system-generators /usr/libexec /etc/bees

cat >/usr/libexec/ryven-bees-configure <<'EOF'
#!/bin/bash
set -euo pipefail
UUID=$(findmnt -n -o UUID /var/home 2>/dev/null || findmnt -n -o UUID /)
[[ -n ${UUID} ]] || exit 0
FSTYPE=$(findmnt -n -o FSTYPE /var/home 2>/dev/null || findmnt -n -o FSTYPE /)
[[ ${FSTYPE} == btrfs ]] || exit 0
mkdir -p /etc/bees
cat >/etc/bees/${UUID}.conf <<CONF
UUID=${UUID}
CONF
EOF
chmod +x /usr/libexec/ryven-bees-configure

cat >/usr/lib/systemd/system-generators/ryven-bees-generator <<'EOF'
#!/bin/bash
set -euo pipefail
normal=${1:-/run/systemd/generator}
UUID=$(findmnt -n -o UUID /var/home 2>/dev/null || findmnt -n -o UUID / || true)
[[ -n ${UUID} ]] || exit 0
FSTYPE=$(findmnt -n -o FSTYPE /var/home 2>/dev/null || findmnt -n -o FSTYPE / || true)
[[ ${FSTYPE} == btrfs ]] || exit 0
mkdir -p "${normal}/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/beesd@.service "${normal}/beesd@${UUID}.service"
ln -sf "../beesd@${UUID}.service" "${normal}/multi-user.target.wants/beesd@${UUID}.service"
EOF
chmod +x /usr/lib/systemd/system-generators/ryven-bees-generator

mkdir -p /usr/lib/systemd/system
cat >/usr/lib/systemd/system/ryven-bees-configure.service <<'EOF'
[Unit]
Description=Write beesd UUID config for the host btrfs
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/libexec/ryven-bees-configure
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable ryven-bees-configure.service

### OpenRazer / Polychromatic

install_priority openrazer-daemon python3-openrazer
getent group plugdev >/dev/null || groupadd -r plugdev

if ! dnf5 -y install polychromatic; then
  dnf5 -y config-manager addrepo --from-repofile=https://openrazer.github.io/hardware:razer.repo --overwrite
  dnf5 -y install polychromatic
  shopt -s nullglob
  for repo in /etc/yum.repos.d/*razer*.repo; do
    sed -i 's/^enabled=1/enabled=0/' "${repo}"
  done
fi

### MangoHud

install_priority mangohud obs-vkcapture

if dnf5 list --available --enablerepo="${TERRA_REPOS}" --enablerepo="${FUSION_REPOS}" mangohud.i686 >/dev/null 2>&1; then
  install_priority mangohud.i686
fi
if dnf5 list --available --enablerepo="${TERRA_REPOS}" --enablerepo="${FUSION_REPOS}" obs-vkcapture.i686 >/dev/null 2>&1; then
  install_priority obs-vkcapture.i686
fi
install_any goverlay

### I/O schedulers

mkdir -p /usr/lib/udev/rules.d
cat >/usr/lib/udev/rules.d/60-ryven-io-scheduler.rules <<'EOF'
# NVMe → kyber
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme*", ATTR{queue/scheduler}=="*kyber*", ATTR{queue/scheduler}="kyber"
# Rotational HDD → bfq
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd*|vd*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}=="*bfq*", ATTR{queue/scheduler}="bfq"
# Non-rotational SATA/virtio SSD → mq-deadline
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd*|vd*|mmcblk*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}=="*mq-deadline*", ATTR{queue/scheduler}="mq-deadline"
EOF
rm -f /usr/lib/udev/rules.d/60-ryven-kyber.rules

### uupd / topgrade

install_priority uupd
install_priority topgrade

if [[ -f /etc/rpm-ostreed.conf ]]; then
  if grep -q '^AutomaticUpdatePolicy=' /etc/rpm-ostreed.conf; then
    sed -i 's/^AutomaticUpdatePolicy=.*/AutomaticUpdatePolicy=none/' /etc/rpm-ostreed.conf
  fi
fi

systemctl enable uupd.timer

### First-boot Flatpaks

dnf5 -y install flatpak

mkdir -p /usr/share/ryven /usr/libexec /usr/lib/systemd/system

cat >/usr/share/ryven/flatpaks <<'EOF'
com.github.tchx84.Flatseal
io.github.flattool.Warehouse
it.mijorus.gearlever
io.github.kolunmi.Bazaar
EOF

cat >/usr/libexec/ryven-flatpak-setup <<'EOF'
#!/bin/bash
set -euo pipefail
stamp=/var/lib/ryven/flatpak-setup.stamp
[[ -f ${stamp} ]] && exit 0
flatpak remote-add --if-not-exists --system flathub \
  https://dl.flathub.org/repo/flathub.flatpakrepo
mapfile -t apps < /usr/share/ryven/flatpaks
flatpak install --system --noninteractive --or-update flathub "${apps[@]}"
mkdir -p /var/lib/ryven
touch "${stamp}"
EOF
chmod +x /usr/libexec/ryven-flatpak-setup

cat >/usr/lib/systemd/system/ryven-flatpak-setup.service <<'EOF'
[Unit]
Description=Install Ryven system Flatpaks onto /var
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/ryven/flatpak-setup.stamp

[Service]
Type=oneshot
ExecStart=/usr/libexec/ryven-flatpak-setup
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable ryven-flatpak-setup.service

### Terra desktop/games stack

install_any ghostty-tip ghostty
install_priority \
  t3code \
  heroic-games-launcher \
  protonplus \
  vulkan-low-latency-layer \
  ananicy-cpp \
  cachyos-ananicy-rules \
  android-udev-rules \
  bpftune-gaming \
  lact \
  darkly

# Name: terra-gamescope on terrapkg f44. Not in terra44 / terra44-multimedia /
# terra44-mesa primary metadata (2026-09-02). Do not install Fedora gamescope.
if ! install_priority terra-gamescope; then
  echo "terra-gamescope unpublished on Terra f44 repos; compositor omitted" >&2
fi

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

### proton-cachyos tarball

VER=11.0-20260703-slr
BASE="https://github.com/CachyOS/proton-cachyos/releases/download/cachyos-${VER}"
TAR="proton-cachyos-${VER}-x86_64.tar.xz"
SUM="proton-cachyos-${VER}-x86_64.sha512sum"
DEST=/usr/share/steam/compatibilitytools.d

dnf5 -y install tar xz curl coreutils

mkdir -p /tmp/proton-cachyos "${DEST}"
curl -fsSL -o "/tmp/proton-cachyos/${SUM}" "${BASE}/${SUM}"
curl -fL --retry 3 -o "/tmp/proton-cachyos/${TAR}" "${BASE}/${TAR}"
(cd /tmp/proton-cachyos && sha512sum -c "${SUM}")

tar -xJf "/tmp/proton-cachyos/${TAR}" -C "${DEST}"
# Steam looks for a directory containing compatibilitytool.vdf
if [[ ! -f ${DEST}/proton-cachyos/compatibilitytool.vdf ]] && \
   [[ ! -f ${DEST}/proton-cachyos-${VER}/compatibilitytool.vdf ]]; then
  vdf=$(find "${DEST}" -name compatibilitytool.vdf -print -quit)
  if [[ -z ${vdf} ]]; then
    echo "proton-cachyos tarball missing compatibilitytool.vdf" >&2
    find "${DEST}" -maxdepth 3 >&2
    exit 1
  fi
fi

rm -rf /tmp/proton-cachyos
echo "proton-cachyos ${VER} installed under ${DEST}"

### Build-time invariants

fail=0
check() {
  local name=$1
  shift
  if "$@"; then
    echo "OK  ${name}"
  else
    echo "FAIL ${name}" >&2
    fail=1
  fi
}

check "firefox rpm" rpm -q firefox
check "git on PATH" command -v git
check "gh on PATH" command -v gh
check "mise on PATH" command -v mise
check "nvidia kargs" test -f /usr/lib/bootc/kargs.d/00-nvidia.toml
check "nvidia modprobe" test -f /usr/lib/modprobe.d/nvidia-gaming.conf
check "shader cache env" test -f /usr/lib/environment.d/50-ryven-shader-cache.conf
check "zswap kargs" test -f /usr/lib/bootc/kargs.d/10-zswap.toml
check "amd zen kargs" test -f /usr/lib/bootc/kargs.d/20-amd-zen.toml
check "ujust wrapper" test -x /usr/bin/ujust
check "ryven justfile" test -f /usr/share/ryven/justfile
check "chronyd enabled" bash -c '[[ $(systemctl is-enabled chronyd.service) == enabled ]]'
check "sshd not enabled" bash -c 's=$(systemctl is-enabled sshd.service 2>/dev/null || true); [[ $s != enabled ]]'
check "firewalld enabled" bash -c '[[ $(systemctl is-enabled firewalld.service) == enabled ]]'
check "nvidia kmod present" bash -c 'find /usr/lib/modules -name "nvidia*.ko*" -print -quit | grep -q .'
check "ffmpeg rpm" rpm -q ffmpeg
check "libva-nvidia-driver" rpm -q libva-nvidia-driver
check "zram generator disabled" bash -c '! systemctl is-enabled systemd-zram-setup@zram0.service 2>/dev/null | grep -qx enabled'
check "no firefox flatpak" bash -c '! command -v flatpak >/dev/null || ! flatpak info --system org.mozilla.firefox >/dev/null 2>&1'
check "ryven look-and-feel" test -f /usr/share/plasma/look-and-feel/org.ryven.desktop/metadata.json
check "ryven color scheme" test -f /usr/share/color-schemes/Ryven.colors
check "ryven wallpaper" test -f /usr/share/wallpapers/Ryven/contents/images/3840x2160.png
check "ryven kdeglobals" grep -q 'LookAndFeelPackage=org.ryven.desktop' /etc/xdg/kdeglobals
check "inter font default" grep -q 'font=Inter,' /etc/xdg/kdeglobals
check "darkly widgetStyle" grep -q 'widgetStyle=Darkly' /etc/xdg/kdeglobals
check "plasmalogin enabled" bash -c '[[ $(systemctl is-enabled plasmalogin.service) == enabled ]]'
check "sddm not enabled" bash -c 's=$(systemctl is-enabled sddm.service 2>/dev/null || true); [[ $s != enabled ]]'
check "io scheduler udev" test -f /usr/lib/udev/rules.d/60-ryven-io-scheduler.rules
check "ntsync udev" test -f /usr/lib/udev/rules.d/40-ryven-ntsync.rules
check "ntsync modules-load" test -f /usr/lib/modules-load.d/ntsync.conf
check "desktop sysctl" test -f /usr/lib/sysctl.d/70-ryven-desktop.conf
check "scx default lavd" grep -q 'SCX_SCHEDULER=scx_lavd' /etc/default/scx
check "scx_loader.toml" grep -q 'default_sched = "scx_lavd"' /etc/scx_loader.toml
check "scx_loader enabled" bash -c '[[ $(systemctl is-enabled scx_loader.service) == enabled ]]'
check "ananicy-cpp enabled" bash -c '[[ $(systemctl is-enabled ananicy-cpp.service) == enabled ]]'
check "bpftune enabled" bash -c '[[ $(systemctl is-enabled bpftune.service) == enabled ]]'
check "no cardwire" bash -c '! rpm -q cardwire >/dev/null 2>&1'
check "proton wayland" grep -q 'PROTON_ENABLE_WAYLAND=1' /usr/lib/environment.d/60-ryven-proton.conf
check "no WINEFSYNC" bash -c '! grep -q WINEFSYNC /usr/lib/environment.d/60-ryven-proton.conf'
check "flatpak first-boot unit" test -f /usr/lib/systemd/system/ryven-flatpak-setup.service
check "bees generator" test -x /usr/lib/systemd/system-generators/ryven-bees-generator
check "greenboot rpm" rpm -q greenboot
check "greenboot redboot-auto-reboot" bash -c '
  if [[ -f /usr/lib/systemd/system/redboot-auto-reboot.service ]]; then
    [[ $(systemctl is-enabled redboot-auto-reboot.service) == enabled ]]
  else
    true
  fi
'
check "proton-cachyos vdf" bash -c 'find /usr/share/steam/compatibilitytools.d -name compatibilitytool.vdf | grep -q .'
# terra-gamescope: f44 spec exists, no NEVRA in terra44/multimedia/mesa (2026-09-02).
check "helium-browser-bin" rpm -q helium-browser-bin
check "gpu-screen-recorder" rpm -q gpu-screen-recorder
check "polychromatic" rpm -q polychromatic
check "docker group empty or absent" bash -c '
  if getent group docker >/dev/null; then
    members=$(getent group docker | cut -d: -f4)
    [[ -z ${members} ]]
  else
    true
  fi
'

if [[ ${fail} -ne 0 ]]; then
  echo "Image invariant checks failed." >&2
  exit 1
fi

echo "Image invariant checks passed."
