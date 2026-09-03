#!/bin/bash
# Ryven-WL compose. PID 1 of the Containerfile RUN; systemd is not the init.
# Base: ghcr.io/ublue-os/base-main (Fedora 44, no DE). Desktop is Hyprland +
# QuickShell. Latest Hyprland stack comes from COPR nett00n/hyprland (Fedora 44
# ready; solopasha is abandoned). COPR is last-resort after Terra/Fusion/Fedora
# miss; repo files are disabled at rest. Weekly image rebuilds pick up latest.
#
# Same product rules as Ryven: no terra-release-nvidia, no mesa-freeworld swap,
# no CUDA, no Docker, no LIBVA_DRIVER_NAME=nvidia, zswap on / zram off,
# CachyOS kernel (COPR) + RPMFusion akmod-nvidia built at compose time.

set -euxo pipefail
# shellcheck source=/dev/null
source /ctx/common.sh

cp -avf /ctx/system_files/. /
cp -avf /ctx/system_files_wl/. /

dnf5 -y install \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_RELEASE}.noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_RELEASE}.noarch.rpm"

# Terra bootstrap retried: Terra publishes metadata non-atomically and
# mirrors can serve stale repomd files, so a fresh repomd can reference
# files that 404, or fail its checksum, until the publish settles.
for terra_attempt in 1 2 3 4 5; do
  if dnf5 -y install --nogpgcheck \
    --repofrompath "terra,https://repos.fyralabs.com/terra${FEDORA_RELEASE}" \
    terra-release && \
    dnf5 -y install --enablerepo=terra \
      terra-release-extras \
      terra-release-mesa \
      terra-release-multimedia; then
    break
  fi
  [[ ${terra_attempt} -lt 5 ]] || die 'Terra bootstrap failed after 5 attempts'
  dnf5 clean expire-cache --repoid=terra 2>/dev/null || dnf5 clean all
  sleep 30
done
disable_yum_repos /etc/yum.repos.d/rpmfusion*.repo /etc/yum.repos.d/*terra*.repo

stub_kernel_install_hooks
trap restore_kernel_install_hooks ERR
dnf5 -y install jq

local_pkg=
for local_pkg in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra; do
  if have_rpm "${local_pkg}"; then
    rpm --erase "${local_pkg}" --nodeps
  fi
done
# Wipe BEFORE installing CachyOS: the wildcard must never run after the
# CachyOS module tree lands.
rm -rf /usr/lib/modules/*

install_cachyos_kernel
rpm -q kernel-cachyos-lto-core >/dev/null ||
  die 'kernel-cachyos-lto-core missing after COPR install'

KVER=$(rpm -q kernel-cachyos-lto-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | LC_ALL=C sort -V | tail -n1)
[[ -n "${KVER}" ]] || die 'cannot determine installed CachyOS kernel version'

# NVIDIA kernel modules built for the CachyOS kernel via RPMFusion akmod
# (no prebuilt modules exist for it; see build.sh for the full rationale).
# The LTO kernel tree is clang-built, so clang/llvm join the build deps.
dnf5 -y install gcc make clang llvm
dnf5 -y install "${FUSION_REPOS[@]/#/--enablerepo=}" "${NVIDIA_EXCLUDE_REPOS[@]}" \
  akmod-nvidia \
  xorg-x11-drv-nvidia xorg-x11-drv-nvidia-libs \
  xorg-x11-drv-nvidia-libs.i686 \
  xorg-x11-drv-nvidia-cuda xorg-x11-drv-nvidia-cuda-libs \
  xorg-x11-drv-nvidia-cuda-libs.i686
akmods --force --kernels "${KVER}"
find "/usr/lib/modules/${KVER}" -name 'nvidia.ko*' -print -quit | grep -q . ||
  die "akmods produced no nvidia.ko for ${KVER}"
dnf5 -y remove gcc make clang llvm

# SELinux booleans for custom kernels and gaming runtimes (Steam/Proton JIT,
# out-of-tree module loads). Each applied independently so one missing
# boolean cannot skip the rest; all non-fatal with a warning.
for sebool in domain_kernel_load_modules selinuxuser_execmod selinuxuser_execstack selinuxuser_execheap; do
  setsebool -P "${sebool}" on 2>/dev/null ||
    echo "SELinux boolean ${sebool} unavailable" >&2
done

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
  "${FUSION_REPOS[@]/#/--enablerepo=}" "${NVIDIA_EXCLUDE_REPOS[@]}" \
  --exclude='cuda*' \
  --exclude='*nvidia*cuda*' \
  libva-nvidia-driver.x86_64 \
  libva-nvidia-driver.i686
install_priority vulkan-loader.x86_64 vulkan-loader.i686 vulkan-tools egl-wayland
if ! have_rpm nvidia-settings; then
  dnf5 -y install "${FUSION_REPOS[@]/#/--enablerepo=}" "${NVIDIA_EXCLUDE_REPOS[@]}" --exclude='cuda*' nvidia-settings
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
  NetworkManager-wifi NetworkManager-bluetooth NetworkManager-tui \
  nm-connection-editor network-manager-applet \
  blueman brightnessctl playerctl pavucontrol \
  thunar thunar-volman gvfs gvfs-mtp gvfs-gphoto2 \
  gnome-keyring polkit \
  google-noto-sans-fonts rsms-inter-fonts jetbrains-mono-fonts \
  fontawesome-fonts

if have_rpm docker-ce || have_rpm docker; then
  die 'docker RPM must not be present'
fi

systemctl enable chronyd.service podman.socket firewalld.service NetworkManager.service
systemctl disable systemd-timesyncd.service 2>/dev/null || true
systemctl mask systemd-timesyncd.service 2>/dev/null || true
systemctl disable sshd.service 2>/dev/null || true
systemctl mask sshd.service 2>/dev/null || true

copr_install_isolated vdanielmo/git-credential-manager git-credential-manager
if ! dnf5 -y install mise; then
  vendor_repo_install '*mise*.repo' https://mise.jdx.dev/rpm/mise.repo mise
fi

install_priority bun-bin
install_any rust-deno deno
install_priority zed
install_priority mpv yt-dlp-git python-yt-dlp-ejs
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

# scx-manager GUI from the CachyOS addons COPR (isolated: repo disabled
# again after install). On-demand alternative to the boot-enabled scx_loader.
copr_install_isolated bieszczaders/kernel-cachyos-addons scx-manager

install_any ghostty-tip ghostty
install_any helium-browser-bin helium-browser
install_priority t3code opencode-cli
if ! install_priority gpu-screen-recorder; then
  copr_install_isolated brycensranch/gpu-screen-recorder-git gpu-screen-recorder
fi

# Hyprland latest: Terra/Fedora first, then isolated nett00n/hyprland (f44).
# Do not leave the COPR enabled on the booted image.
hypr_pkgs=(
  hyprland
  xdg-desktop-portal-hyprland
  xdg-desktop-portal-gtk
  hyprpaper hyprpicker hypridle hyprlock hyprcursor
  hyprpolkitagent hyprsunset hyprlauncher hyprsysteminfo
  hyprland-qt-support hyprqt6engine hyprpwcenter hyprshutdown
  hyprshot hyprtoolkit
  quickshell
  uwsm
  cliphist satty
)
dnf5 -y copr enable nett00n/hyprland
# Never leave the COPR enabled: restore hooks and disable it on any failure.
trap 'dnf5 -y copr disable nett00n/hyprland || true; restore_kernel_install_hooks' ERR
missing_pkgs=()
for pkg in "${hypr_pkgs[@]}"; do
  if have_rpm "${pkg}"; then
    continue
  fi
  if ! dnf5 -y install "${TERRA_REPOS[@]/#/--enablerepo=}" "${FUSION_REPOS[@]/#/--enablerepo=}" "${pkg}"; then
    if ! dnf5 -y install "${pkg}"; then
      echo "No NEVRA for ${pkg} (Hyprland stack)" >&2
      missing_pkgs+=("${pkg}")
    fi
  fi
done
dnf5 -y copr disable nett00n/hyprland
trap restore_kernel_install_hooks ERR
if ((${#missing_pkgs[@]})); then
  echo "Hyprland stack packages omitted (no NEVRA): ${missing_pkgs[*]}" >&2
fi
have_rpm hyprland || die 'hyprland RPM missing after nett00n/hyprland COPR'
have_rpm quickshell || die 'quickshell RPM missing after nett00n/hyprland COPR'

# Must-have Wayland utilities (wiki + requested clipboard stack).
install_priority \
  wl-clipboard dunst grim slurp fuzzel \
  kde-connect \
  wf-recorder \
  android-tools libimobiledevice
install_wl_clip_persist
if ! install_any greetd; then
  die 'greetd missing'
fi
# tuigreet is the configured greeter command in system_files_wl greetd config;
# a missing binary means no graphical login, so this is fatal like Sericea.
install_any tuigreet greetd-tuigreet || die 'tuigreet/greetd-tuigreet missing: greetd would have no greeter'

if have_rpm zram-generator-defaults || have_rpm zram-generator; then
  dnf5 -y remove zram-generator-defaults zram-generator
fi
mkdir -p /usr/lib/systemd /etc/systemd/system
printf '%s\n' '# Ryven-WL: zram disabled. Compressed RAM is zswap.' \
  >/usr/lib/systemd/zram-generator.conf
ln -sfn /dev/null /etc/systemd/system/systemd-zram-setup@zram0.service
systemctl mask systemd-zram-setup@zram0.service

# greetd is the greeter (no SDDM / plasmalogin on this image).
getent passwd greeter >/dev/null || useradd -r -s /usr/bin/nologin greeter
systemctl enable greetd.service
if [[ -f /usr/lib/systemd/system/sddm.service ]]; then
  systemctl disable sddm.service || true
  systemctl mask sddm.service || true
fi

enabled=0
shopt -s nullglob
for unit in /usr/lib/systemd/system/greenboot*.service /usr/lib/systemd/system/redboot*.service; do
  systemctl enable "$(basename "${unit}")"
  enabled=1
done
((enabled)) || die 'greenboot installed but no units under /usr/lib/systemd/system'

if [[ -f /usr/lib/os-release ]]; then
  sed -i \
    -e 's/^NAME=.*/NAME="Ryven WL"/' \
    -e 's/^PRETTY_NAME=.*/PRETTY_NAME="Ryven WL (Hyprland)"/' \
    /usr/lib/os-release
  if grep -q '^IMAGE_ID=' /usr/lib/os-release; then
    sed -i 's/^IMAGE_ID=.*/IMAGE_ID="ryven-wl"/' /usr/lib/os-release
  else
    # Start on a fresh line even if the file lacks a trailing newline.
    [[ -z $(tail -c1 /usr/lib/os-release) ]] || printf '\n' >>/usr/lib/os-release
    echo 'IMAGE_ID="ryven-wl"' >>/usr/lib/os-release
  fi
fi
mkdir -p /etc/default/grub.d
cat >/etc/default/grub.d/50-ryven.cfg <<'EOF'
GRUB_DISTRIBUTOR="Ryven WL"
EOF

# Ship Hyprland/QuickShell defaults into skel and XDG. Fail with a clear
# message when an expected source file moved instead of a bare cp error.
require_src() {
  [[ -f $1 ]] || die "expected compose source missing: $1"
}
require_src /usr/share/hypr/hyprland.conf
require_src /usr/share/hypr/hyprpaper.conf
require_src /usr/share/hypr/hypridle.conf
require_src /usr/share/hypr/hyprlock.conf
require_src /etc/xdg/quickshell/shell.qml
compgen -G '/usr/share/hypr/*.conf' >/dev/null || die 'no Hyprland configs under /usr/share/hypr'
mkdir -p /etc/skel/.config/hypr /etc/skel/.config/quickshell /etc/xdg/hypr
cp -a /usr/share/hypr/hyprland.conf /etc/skel/.config/hypr/hyprland.conf
cp -a /usr/share/hypr/hyprpaper.conf /etc/skel/.config/hypr/hyprpaper.conf
cp -a /usr/share/hypr/hypridle.conf /etc/skel/.config/hypr/hypridle.conf
cp -a /usr/share/hypr/hyprlock.conf /etc/skel/.config/hypr/hyprlock.conf
cp -a /etc/xdg/quickshell/shell.qml /etc/skel/.config/quickshell/shell.qml
cp -a /usr/share/hypr/*.conf /etc/xdg/hypr/

mkdir -p /etc/xdg/uwsm
cat >/etc/xdg/uwsm/env-hyprland <<'EOF'
export NVD_BACKEND=direct
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export ELECTRON_OZONE_PLATFORM_HINT=auto
EOF

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
# Pinned checksum of PROTON_TAR. Update together with PROTON_CACHYOS_VER.
PROTON_SHA512="713fe008d67e3491aef3b5b1d9ae2c112d7c2b58b3f23fc2387d1122fc131ff7e7f0ea27c67bf27973d906bdce6235c34098530ec4c786059438b153c6e16187"
PROTON_DEST=/usr/share/steam/compatibilitytools.d
dnf5 -y install tar xz curl coreutils
mkdir -p /tmp/proton-cachyos "${PROTON_DEST}"
curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "/tmp/proton-cachyos/${PROTON_SUM}" "${PROTON_BASE}/${PROTON_SUM}"
curl -fL --proto '=https' --retry 3 --retry-all-errors -o "/tmp/proton-cachyos/${PROTON_TAR}" "${PROTON_BASE}/${PROTON_TAR}"
(cd /tmp/proton-cachyos && sha512sum -c "${PROTON_SUM}")
(cd /tmp/proton-cachyos && echo "${PROTON_SHA512}  ${PROTON_TAR}" | sha512sum -c -)
tar -xJf "/tmp/proton-cachyos/${PROTON_TAR}" -C "${PROTON_DEST}"
if [[ ! -f ${PROTON_DEST}/proton-cachyos/compatibilitytool.vdf && ! -f ${PROTON_DEST}/proton-cachyos-${PROTON_CACHYOS_VER}/compatibilitytool.vdf ]]; then
  vdf=$(find "${PROTON_DEST}" -name compatibilitytool.vdf -print -quit)
  [[ -n "${vdf}" ]] || die 'proton-cachyos tarball missing compatibilitytool.vdf'
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
check 'hyprland rpm' rpm -q hyprland
check 'quickshell rpm' rpm -q quickshell
check 'hyprland.conf' test -f /usr/share/hypr/hyprland.conf
check 'master layout' grep -q 'layout = master' /usr/share/hypr/hyprland.conf
check 'tearing' grep -q 'allow_tearing = true' /usr/share/hypr/hyprland.conf
check 'no LIBVA_DRIVER_NAME=nvidia' bash -c '! grep -rE "^[[:space:]]*LIBVA_DRIVER_NAME=nvidia" /usr/share/hypr /usr/lib/environment.d /etc/xdg/uwsm 2>/dev/null'
check 'cliphist' rpm -q cliphist
check 'wl-clipboard' rpm -q wl-clipboard
check 'wl-clip-persist' command -v wl-clip-persist
check 'dunst' rpm -q dunst
check 'xdg-desktop-portal-hyprland' rpm -q xdg-desktop-portal-hyprland
check 'greetd enabled' unit_enabled greetd.service
check 'nvidia kargs' test -f /usr/lib/bootc/kargs.d/00-nvidia.toml
check 'zswap kargs' test -f /usr/lib/bootc/kargs.d/10-zswap.toml
check 'ffmpeg rpm' rpm -q ffmpeg
check 'no docker' bash -c '! rpm -q docker >/dev/null 2>&1 && ! rpm -q docker-ce >/dev/null 2>&1'
if [[ ${fail} -ne 0 ]]; then
  die 'Ryven-WL invariant checks failed.'
fi
echo 'Ryven-WL invariant checks passed.'
