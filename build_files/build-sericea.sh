#!/bin/bash
# Ryven-Sericea compose. Base: ghcr.io/ublue-os/sericea-main (Fedora 44 Sway).
# Same product rules as Ryven/WL: no terra-release-nvidia, no mesa-freeworld
# swap, no CUDA, no Docker, no LIBVA_DRIVER_NAME=nvidia, zswap on / zram off,
# OGC kernel + ublue akmods-nvidia-open:ogc-44.

set -ouex pipefail
# shellcheck source=/dev/null
source /ctx/common.sh

cp -avf /ctx/system_files/. /
cp -avf /ctx/system_files_sericea/. /

dnf5 -y install \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_RELEASE}.noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_RELEASE}.noarch.rpm"

dnf5 -y install --nogpgcheck \
  --repofrompath "terra,https://repos.fyralabs.com/terra${FEDORA_RELEASE}" \
  terra-release
dnf5 -y install --enablerepo=terra \
  terra-release-extras \
  terra-release-mesa \
  terra-release-multimedia
disable_yum_repos /etc/yum.repos.d/rpmfusion*.repo /etc/yum.repos.d/*terra*.repo

stub_kernel_install_hooks
dnf5 -y install jq skopeo
extract_ogc_kernel /tmp/kernel-rpms
compgen -G '/tmp/kernel-rpms/kernel-core-*.rpm' >/dev/null ||
  die 'OGC kernel-core RPM missing under /tmp/kernel-rpms'

local_pkg=
for local_pkg in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-tools kernel-tools-libs; do
  if have_rpm "${local_pkg}"; then
    rpm --erase "${local_pkg}" --nodeps
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
if compgen -G '/tmp/akmods-rpms/ublue-os/ublue-os-akmods-addons*.rpm' >/dev/null; then
  dnf5 -y install /tmp/akmods-rpms/ublue-os/ublue-os-akmods-addons*.rpm
elif compgen -G '/tmp/akmods-rpms/ublue-os/ublue-os-akmods*.rpm' >/dev/null; then
  dnf5 -y install /tmp/akmods-rpms/ublue-os/ublue-os-akmods*.rpm
fi

shopt -s nullglob
install_kmod_bundle \
  /tmp/akmods-rpms/kmods/kmod-xone*.rpm \
  /tmp/akmods-rpms/common/*xone*kmod-common*.rpm \
  /tmp/akmods-rpms/kmods/kmod-xpadneo*.rpm \
  /tmp/akmods-rpms/common/*xpadneo*kmod-common*.rpm \
  /tmp/akmods-rpms/kmods/kmod-openrazer*.rpm \
  /tmp/akmods-rpms/common/*openrazer*kmod-common*.rpm
install_kmod_bundle \
  /tmp/akmods-extra-rpms/kmods/kmod-*ryzen*smu*.rpm \
  /tmp/akmods-extra-rpms/extra/kmod-*ryzen*smu*.rpm \
  /tmp/akmods-extra-rpms/kmods/kmod-*zenergy*.rpm \
  /tmp/akmods-extra-rpms/extra/kmod-*zenergy*.rpm

if [[ -f /etc/yum.repos.d/_copr_ublue-os-akmods.repo ]]; then
  sed -i 's@enabled=1@enabled=0@g' /etc/yum.repos.d/_copr_ublue-os-akmods.repo
fi

AKMODNV_PATH=/tmp/akmods-nvidia-rpms
[[ -f ${AKMODNV_PATH}/kmods/nvidia-vars ]] ||
  die "akmods-nvidia-open:ogc-44 missing ${AKMODNV_PATH}/kmods/nvidia-vars"
INSTALL_SH=
if [[ -x ${AKMODNV_PATH}/ublue-os/nvidia-install.sh || -f ${AKMODNV_PATH}/ublue-os/nvidia-install.sh ]]; then
  INSTALL_SH=${AKMODNV_PATH}/ublue-os/nvidia-install.sh
else
  INSTALL_SH=$(find /tmp/akmods-nvidia-rpms -name nvidia-install.sh -type f -print -quit)
fi
[[ -n ${INSTALL_SH} ]] || die 'nvidia-install.sh missing from akmods-nvidia-open:ogc-44'
IMAGE_NAME=base AKMODNV_PATH="${AKMODNV_PATH}" MULTILIB=1 bash "${INSTALL_SH}"

rm -f /usr/share/vulkan/icd.d/nouveau_icd.*.json
if [[ -e /usr/lib64/libnvidia-ml.so.1 ]]; then
  ln -sf libnvidia-ml.so.1 /usr/lib64/libnvidia-ml.so
fi
depmod -a "${KVER}"
restore_kernel_install_hooks

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

dnf5 -y install \
  --enablerepo="${FUSION_REPOS}" \
  --exclude='cuda*' \
  --exclude='*nvidia*cuda*' \
  libva-nvidia-driver.x86_64 \
  libva-nvidia-driver.i686
install_priority vulkan-loader.x86_64 vulkan-loader.i686 vulkan-tools egl-wayland
if ! have_rpm nvidia-settings; then
  dnf5 -y install --enablerepo="${FUSION_REPOS}" --exclude='cuda*' nvidia-settings
fi

dnf5 -y install \
  just mokutil shim efibootmgr \
  cryptsetup clevis clevis-luks clevis-dracut tpm2-tools \
  chrony podman podman-compose firewalld \
  git gh git-credential-libsecret \
  sudo-rs flatpak \
  greenboot greenboot-default-health-checks \
  firefox \
  pipewire pipewire-pulseaudio pipewire-alsa wireplumber \
  qt5-qtwayland qt6-qtwayland \
  xdg-utils xdg-user-dirs \
  brightnessctl playerctl pavucontrol \
  gnome-keyring polkit \
  google-noto-sans-fonts rsms-inter-fonts jetbrains-mono-fonts \
  fontawesome-fonts

if have_rpm docker-ce || have_rpm docker; then
  die 'docker RPM must not be present'
fi

systemctl enable chronyd.service podman.socket firewalld.service
systemctl disable systemd-timesyncd.service 2>/dev/null || true
systemctl mask systemd-timesyncd.service 2>/dev/null || true
systemctl disable sshd.service 2>/dev/null || true
systemctl mask sshd.service 2>/dev/null || true

copr_install_isolated vdanielmo/git-credential-manager git-credential-manager
if ! dnf5 -y install mise; then
  vendor_repo_install '*mise*.repo' https://mise.jdx.dev/rpm/mise.repo mise
fi

install_priority bun-bin || echo 'bun-bin unpublished' >&2
install_any rust-deno deno || echo 'deno unpublished' >&2
install_priority zed || echo 'zed unpublished' >&2
install_priority mpv || echo 'mpv unpublished' >&2
install_priority yt-dlp-git || echo 'yt-dlp-git unpublished' >&2
install_priority python-yt-dlp-ejs || echo 'python-yt-dlp-ejs unpublished' >&2
swap_ffmpeg_priority
install_priority steam
install_priority scx-scheds scx-tools
mkdir -p /etc /etc/scx_loader /etc/default
cat >/etc/scx_loader.toml <<'EOF'
default_sched = "scx_lavd"
default_mode = "Gaming"

[scheds.scx_lavd]
auto_mode = ["--performance"]
gaming_mode = ["--performance"]
lowlatency_mode = ["--performance"]
powersave_mode = ["--performance"]
EOF
ln -sfn /etc/scx_loader.toml /etc/scx_loader/config.toml
if [[ ! -f /etc/default/scx ]]; then
  printf 'SCX_SCHEDULER=scx_lavd\nSCX_FLAGS=--performance\n' >/etc/default/scx
fi
[[ -f /usr/lib/systemd/system/scx_loader.service ]] ||
  die 'scx-tools did not ship scx_loader.service'
systemctl enable scx_loader.service

install_any ghostty-tip ghostty
install_any helium-browser-bin helium-browser
install_priority t3code opencode-cli
if ! install_priority gpu-screen-recorder; then
  copr_install_isolated brycensranch/gpu-screen-recorder-git gpu-screen-recorder
fi

# Sway is on sericea-main. Refresh to latest Fedora/Terra/Fusion NEVRA.
for pkg in sway swaybg swayidle swaylock waybar wofi fuzzel \
  xdg-desktop-portal-wlr xdg-desktop-portal-gtk; do
  install_priority "${pkg}" || echo "No NEVRA for ${pkg}" >&2
done
have_rpm sway || die 'sway RPM missing on sericea overlay'

for pkg in wl-clipboard dunst grim slurp kde-connect wf-recorder \
  android-tools libimobiledevice satty cliphist; do
  install_priority "${pkg}" || echo "No NEVRA for ${pkg}" >&2
done
if ! install_any wl-clip-persist; then
  echo 'wl-clip-persist unpublished; omitting' >&2
  sed -i '/wl-clip-persist/d' /usr/share/sway/config.d/50-ryven.conf /etc/sway/config.d/50-ryven.conf 2>/dev/null || true
fi

if have_rpm zram-generator-defaults || have_rpm zram-generator; then
  dnf5 -y remove zram-generator-defaults zram-generator
fi
mkdir -p /usr/lib/systemd /etc/systemd/system
printf '%s\n' '# Ryven-Sericea: zram disabled. Compressed RAM is zswap.' \
  >/usr/lib/systemd/zram-generator.conf
ln -sfn /dev/null /etc/systemd/system/systemd-zram-setup@zram0.service
systemctl mask systemd-zram-setup@zram0.service

enabled=0
shopt -s nullglob
for unit in /usr/lib/systemd/system/greenboot*.service /usr/lib/systemd/system/redboot*.service; do
  systemctl enable "$(basename "${unit}")"
  enabled=1
done
((enabled)) || die 'greenboot installed but no units under /usr/lib/systemd/system'

if [[ -f /usr/lib/os-release ]]; then
  sed -i \
    -e 's/^NAME=.*/NAME="Ryven Sericea"/' \
    -e 's/^PRETTY_NAME=.*/PRETTY_NAME="Ryven Sericea (Sway)"/' \
    /usr/lib/os-release
  if grep -q '^IMAGE_ID=' /usr/lib/os-release; then
    sed -i 's/^IMAGE_ID=.*/IMAGE_ID="ryven-sericea"/' /usr/lib/os-release
  else
    echo 'IMAGE_ID="ryven-sericea"' >>/usr/lib/os-release
  fi
fi
mkdir -p /etc/default/grub.d
cat >/etc/default/grub.d/50-ryven.cfg <<'EOF'
GRUB_DISTRIBUTOR="Ryven Sericea"
EOF

# Drop Ryven Sway snippet where Fedora Sway includes extra configs.
mkdir -p /etc/sway/config.d /etc/skel/.config/sway
if [[ -f /usr/share/sway/config.d/50-ryven.conf ]]; then
  cp -a /usr/share/sway/config.d/50-ryven.conf /etc/sway/config.d/50-ryven.conf
  cp -a /usr/share/sway/config.d/50-ryven.conf /etc/skel/.config/sway/ryven.conf
fi

install_priority mangohud obs-vkcapture uupd topgrade ananicy-cpp cachyos-ananicy-rules bpftune-gaming
systemctl enable uupd.timer
if [[ -f /usr/lib/systemd/system/bpftune.service ]]; then
  systemctl enable bpftune.service
fi
if [[ -f /usr/lib/systemd/system/ananicy-cpp.service ]]; then
  systemctl enable ananicy-cpp.service
fi
if [[ -f /etc/rpm-ostreed.conf ]] && grep -q '^AutomaticUpdatePolicy=' /etc/rpm-ostreed.conf; then
  sed -i 's/^AutomaticUpdatePolicy=.*/AutomaticUpdatePolicy=none/' /etc/rpm-ostreed.conf
fi

PROTON_BASE="https://github.com/CachyOS/proton-cachyos/releases/download/cachyos-${PROTON_CACHYOS_VER}"
PROTON_TAR="proton-cachyos-${PROTON_CACHYOS_VER}-x86_64.tar.xz"
PROTON_SUM="proton-cachyos-${PROTON_CACHYOS_VER}-x86_64.sha512sum"
PROTON_DEST=/usr/share/steam/compatibilitytools.d
dnf5 -y install tar xz curl coreutils
mkdir -p /tmp/proton-cachyos "${PROTON_DEST}"
curl -fsSL -o "/tmp/proton-cachyos/${PROTON_SUM}" "${PROTON_BASE}/${PROTON_SUM}"
curl -fL --retry 3 -o "/tmp/proton-cachyos/${PROTON_TAR}" "${PROTON_BASE}/${PROTON_TAR}"
(cd /tmp/proton-cachyos && sha512sum -c "${PROTON_SUM}")
tar -xJf "/tmp/proton-cachyos/${PROTON_TAR}" -C "${PROTON_DEST}"
if [[ ! -f ${PROTON_DEST}/proton-cachyos/compatibilitytool.vdf && ! -f ${PROTON_DEST}/proton-cachyos-${PROTON_CACHYOS_VER}/compatibilitytool.vdf ]]; then
  vdf=$(find "${PROTON_DEST}" -name compatibilitytool.vdf -print -quit)
  [[ -n ${vdf} ]] || die 'proton-cachyos tarball missing compatibilitytool.vdf'
fi
rm -rf /tmp/proton-cachyos

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
check 'sway rpm' rpm -q sway
check 'sway overlay' test -f /usr/share/sway/config.d/50-ryven.conf
check 'tearing' grep -q 'allow_tearing yes' /usr/share/sway/config.d/50-ryven.conf
check 'no LIBVA_DRIVER_NAME=nvidia' bash -c '! grep -r LIBVA_DRIVER_NAME=nvidia /usr/share/sway /usr/lib/environment.d 2>/dev/null'
check 'wl-clipboard' rpm -q wl-clipboard
check 'dunst' rpm -q dunst
check 'nvidia kargs' test -f /usr/lib/bootc/kargs.d/00-nvidia.toml
check 'zswap kargs' test -f /usr/lib/bootc/kargs.d/10-zswap.toml
check 'ffmpeg rpm' rpm -q ffmpeg
check 'no docker' bash -c '! rpm -q docker >/dev/null 2>&1 && ! rpm -q docker-ce >/dev/null 2>&1'
if [[ ${fail} -ne 0 ]]; then
  die 'Ryven-Sericea invariant checks failed.'
fi
echo 'Ryven-Sericea invariant checks passed.'
