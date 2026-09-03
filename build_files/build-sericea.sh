#!/bin/bash
# Ryven-Sericea compose. Base: ghcr.io/ublue-os/base-main + Sway (ublue
# sericea-main is deprecated/unpublished).
# Same product rules as Ryven/WL: no terra-release-nvidia, no mesa-freeworld
# swap, no CUDA toolkit (the driver's CUDA runtime libs ship with the
# driver), no Docker, no LIBVA_DRIVER_NAME=nvidia, zswap on / zram off,
# CachyOS kernel (COPR) + RPMFusion akmod-nvidia built at compose time.

set -euxo pipefail
# shellcheck source=/dev/null
source /ctx/common.sh

# The ublue base image ships /usr/local as a placeholder in a
# non-directory form (a dangling symlink in base-main: `[[ -e ]]` is false
# but `cp -avf` still refuses to lay a directory over it). Replace it in
# any non-directory form before the copy.
if [[ ! -d /usr/local ]]; then
  rm -rf /usr/local
fi

cp -avf /ctx/system_files/. /
cp -avf /ctx/system_files_sericea/. /

# Restore the Fedora atomic layout: on ostree systems /usr/local is a
# symlink into the writable /var (/var/usrlocal); the copy above created a
# real directory under the read-only /usr, which would be unwritable at
# runtime. Relocate its contents and restore the symlink.
if [[ -d /usr/local && ! -L /usr/local ]]; then
  if [[ -e /var/usrlocal || -L /var/usrlocal ]]; then
    cp -a /usr/local/. /var/usrlocal/
  else
    mv /usr/local /var/usrlocal
  fi
  rm -rf /usr/local
fi
if [[ ! -e /usr/local && ! -L /usr/local ]]; then
  ln -s /var/usrlocal /usr/local
fi

dnf5 -y install \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_RELEASE}.noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_RELEASE}.noarch.rpm"

# Terra bootstrap retried: Terra publishes metadata non-atomically and
# mirrors can serve stale repomd files, so a fresh repomd can reference
# files that 404, or fail its checksum, until the publish settles.
for terra_attempt in 1 2 3 4 5 6; do
  if dnf5 -y install --nogpgcheck \
    --repofrompath "terra,https://repos.fyralabs.com/terra${FEDORA_RELEASE}" \
    terra-release && \
    dnf5 -y install --enablerepo=terra \
      terra-release-extras \
      terra-release-mesa \
      terra-release-multimedia; then
    break
  fi
  [[ ${terra_attempt} -lt 6 ]] || die 'Terra bootstrap failed after 6 attempts'
  dnf5 clean metadata 2>/dev/null || dnf5 clean all
  sleep 60
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

# NVIDIA driver stack from Negativo17 + kernel module built for the
# CachyOS kernel via their akmod-nvidia (no prebuilt modules exist for it;
# see build.sh for the full package-by-package rationale). The LTO kernel
# tree is clang-built, so clang/llvm join the build deps.
dnf5 -y install gcc make clang llvm lld
# Install the akmods tooling first: the akmod-nvidia %post (which runs
# inside the Negativo17 transaction below) invokes
# /usr/sbin/akmods-ostree-post, which only exists once the akmods package
# is in place.
dnf5 -y install akmods
# The akmod-nvidia %post builds the kmod inside that transaction; make the
# build work before the transaction runs (see fix_akmods_ostree_post).
fix_akmods_ostree_post
# Add the Negativo17 NVIDIA repo exactly as they instruct (idempotent
# repofile; retried like the other flaky remote bootstraps).
for neg17_attempt in 1 2 3 4 5 6; do
  dnf5 -y config-manager addrepo \
    --from-repofile="https://negativo17.org/repos/fedora-nvidia.repo" && break
  [[ ${neg17_attempt} -lt 6 ]] || die 'Negativo17 addrepo failed after 6 attempts'
  echo "Negativo17 addrepo attempt ${neg17_attempt}/6 failed; retrying in 15s" >&2
  sleep 15
done
# Package map + repo exclusions: see build.sh (same Negativo17 set).
dnf5 -y install --enablerepo=fedora-nvidia "${NVIDIA_EXCLUDE_REPOS[@]}" \
  akmod-nvidia \
  nvidia-driver \
  xorg-x11-nvidia \
  nvidia-driver-libs nvidia-driver-libs.i686 \
  nvidia-driver-common nvidia-driver-common.i686 \
  nvidia-driver-cuda nvidia-driver-cuda-libs nvidia-driver-cuda-libs.i686 \
  nvidia-libXNVCtrl \
  nvidia-settings \
  nvidia-modprobe \
  nvidia-persistenced \
  libnvidia-fbc libnvidia-fbc.i686 \
  nvidia-driver-selinux
# akmods init() opens /run/akmods/akmods.lock; the package's tmpfiles.d line
# (d /run/akmods 0770 root akmods) is normally applied by systemd at boot,
# so create it for this unbooted compose container.
mkdir -p /run/akmods
chown root:akmods /run/akmods
chmod 0770 /run/akmods
# CC=clang: the CachyOS LTO kernel tree is clang-built and its saved CFLAGS
# carry clang-only options (observed: -mretpoline-external-thunk,
# -fexperimental-late-parse-attributes, -fsplit-lto-unit,
# -mstack-alignment=8 all rejected by gcc); the module must be built with
# the same compiler family as the kernel.
# LD=ld.lld: the kernel's LTO config adds `-mllvm ...` to KBUILD_LDFLAGS;
# ld.bfd parses -mllvm as `-m llvm` ("unrecognised emulation mode: llvm"),
# lld accepts it natively.
# KCFLAGS="-fno-lto -fno-split-lto-unit": the kernel CFLAGS enable thin LTO,
# which makes module .o files LLVM bitcode that `ld -r` partial links cannot
# read. KCFLAGS is appended after the kernel CFLAGS, so the module objects
# are plain ELF (standard non-LTO-module-against-LTO-kernel combination).
# MAKEFLAGS: parallel make for the kernel-module build.
CC=clang LD=ld.lld KCFLAGS="-fno-lto -fno-split-lto-unit" MAKEFLAGS="-j$(nproc)" akmods --force --kernels "${KVER}"
if ! find "/usr/lib/modules/${KVER}" -name 'nvidia.ko*' -print -quit | grep -q .; then
  # Dump the akmod build log before failing so CI stdout shows the real
  # compiler error instead of just the missing .ko.
  echo '--- akmods log (last 40 lines) ---' >&2
  tail -n 40 /var/log/akmod/*.log 2>/dev/null || true
  die "akmods produced no nvidia.ko for ${KVER}"
fi
# NOTE: the build toolchain (gcc/make/clang/llvm/lld) is kept until the
# openrazer kmod recovery further down: the Terra openrazer transaction can
# swap the akmods package, requiring one more akmods rebuild. The toolchain
# is removed there, right after the last kmod build.

# SELinux for gaming: Proton/Wine JIT + out-of-tree module loads.
# semanage boolean -m --on (policy default) with setsebool -P fallback.
apply_selinux_game_booleans

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

# VA-API for the NVIDIA driver: official Fedora libva-nvidia-driver again
# as of F44 (only requires libEGL.so.1). Both ISAs (Steam 32-bit).
dnf5 -y install libva-nvidia-driver.x86_64 libva-nvidia-driver.i686
install_priority vulkan-loader.x86_64 vulkan-loader.i686 vulkan-tools egl-wayland

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
  thunar thunar-volman gvfs gvfs-mtp gvfs-smb gvfs-gphoto2 \
  libsecret polkit \
  hunspell hunspell-en hunspell-en-US hunspell-en-GB hunspell-ar \
  aspell aspell-en gspell c-ares \
  tesseract tesseract-langpack-eng tesseract-langpack-ara \
  pciutils policycoreutils-python-utils power-profiles-daemon \
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
# mise (jdx) — mise.jdx.dev/installing-mise.html, dnf section (Fedora 41+):
# the documented install is COPR jdxcode/mise, which tracks mise releases
# (fresher than the official repo, which lags). The COPR file is deliberately
# left enabled at rest so host `dnf upgrade` keeps mise current (scoped
# deviation from the disabled-at-rest rule). System-wide auto self-update is
# shipped via /etc/mise/config.toml (system_files), per the page's guidance
# to keep the CLI on a recent version.
dnf5 -y copr enable jdxcode/mise
if ! dnf5 -y install mise; then
  # Fall back to the official Fedora repo in case it ever carries mise.
  dnf5 -y copr disable jdxcode/mise
  dnf5 -y install mise || die 'mise unavailable (COPR jdxcode/mise + official repo)'
fi

install_priority bun-bin
install_any rust-deno deno
install_priority zed
install_any yt-dlp-git yt-dlp
install_priority mpv
install_any python-yt-dlp-ejs python3-yt-dlp
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

install_priority sway swaybg swayidle swaylock waybar wofi fuzzel \
  xdg-desktop-portal-wlr xdg-desktop-portal-gtk
have_rpm sway || die 'sway RPM missing'

install_priority \
  wl-clipboard dunst grim slurp \
  kde-connect \
  wf-recorder \
  android-tools libimobiledevice
# yazi is not in the Fedora 44 repos; it comes from Terra (repo disabled at
# rest by the Terra bootstrap; weekly rebuild tracks the Terra package).
install_priority yazi
# nohang (Terra; not in Fedora 44): PSI-based low-memory handler that kills
# the offending process before an OOM freeze — for game streaming + agentic
# workloads on a desktop that must stay responsive.
install_priority nohang
systemctl enable nohang.service
# Terra gaming/peripherals stack. falcond REPLACES gamemode (the packages
# Conflicts; falcond does per-game profiled tuning instead). openrazer is
# userspace only: its kmod targets the Terra kernel and would join our
# akmods build, so mainline razer_* drivers (in the CachyOS kernel) are the
# device support; the daemon + python bindings work over them.
# The current ublue F44 base image bundles gamemode (official Fedora
# package); falcond Conflicts with it and the design keeps GameMode
# deliberately absent (invariant: 'gamemode absent (falcond conflict)'),
# so remove it before the falcond install.
if have_rpm gamemode; then
  dnf5 -y remove gamemode
fi
install_priority falcond falcond-profiles
install_priority vicinae lact superfile
install_priority openrazer openrazer-daemon python3-openrazer
systemctl enable falcond.service lactd.service
if [[ -f /usr/lib/systemd/system/openrazer.service ]]; then
  systemctl enable openrazer.service
fi
# The Terra openrazer transaction may swap the akmods package (different
# repo build), overwriting the patched /usr/sbin/akmods-ostree-post; its
# %post kmod build then fails with 'Not to be used as root' (non-critical
# scriptlet error, the packages still install). Re-apply the fix and
# rebuild if the openrazer kmod is missing.
fix_akmods_ostree_post
if have_rpm akmod-openrazer; then
  if ! find "/usr/lib/modules/${KVER}" -name 'openrazer*.ko*' -print -quit | grep -q .; then
    CC=clang LD=ld.lld KCFLAGS="-fno-lto -fno-split-lto-unit" MAKEFLAGS="-j$(nproc)" akmods --force --kernels "${KVER}"
  fi
  find "/usr/lib/modules/${KVER}" -name 'openrazer*.ko*' -print -quit | grep -q . || {
    echo '--- akmods log (last 40 lines) ---' >&2
    tail -n 40 /var/log/akmod/*.log 2>/dev/null || true
    die "akmods produced no openrazer.ko for ${KVER}"
  }
fi
# Last kmod build done - drop the build toolchain from the image.
dnf5 -y remove gcc make clang llvm lld
# falcond OOTB config (README: config.conf is generated on first run, but
# may be packaged — we package it). scx_sched=none: scx_loader owns the
# boot-time scheduler (scx_lavd --performance); per-game profiles still
# switch schedulers per title and restore the pre-profile snapshot.
# vcache_mode=none: AMD 3D vcache feature, these images are NVIDIA.
mkdir -p /etc/falcond
cat >/etc/falcond/config.conf <<'EOF'
enable_performance_mode = true
scx_sched = none
scx_sched_props = default
vcache_mode = none
profile_mode = none
poll_interval_ms = 9000
EOF
# Template user profile (copy via `ujust falcond-profile name=<game-exe>`).
install -D -m 0644 /usr/share/ryven/falcond/ryven-gaming-template.conf \
  /usr/share/falcond/profiles/user/ryven-gaming-template.conf
# BetterBird: latest x86_64 release pulled at compose time (see
# install_betterbird in common.sh); desktop entry + icon ship in
# system_files.
install_betterbird
install_priority satty || copr_install_isolated nett00n/hyprland satty
install_priority cliphist || copr_install_isolated nett00n/hyprland cliphist
install_wl_clip_persist
# oo7 replaces gnome-keyring as the Secret Service keyring (see common.sh).
install_oo7
install_priority greetd
install_any tuigreet greetd-tuigreet

getent passwd greeter >/dev/null || useradd -r -s /usr/bin/nologin greeter
systemctl enable greetd.service
# First-boot PAM wiring: pam_oo7.so auto-unlock at greetd + keyring password
# sync in /etc/pam.d/passwd (guarded, idempotent, stamped).
systemctl enable ryven-keyring-pam.service
# KDE Connect LAN access: mdns discovery + 1714/tcp through firewalld.
systemctl enable ryven-kdeconnect-firewall.service
# PCI latency timers (CachyOS-style) at boot, before any GUI starts.
systemctl enable ryven-pci-latency.service
if [[ -f /usr/lib/systemd/system/sddm.service ]]; then
  systemctl disable sddm.service || true
  systemctl mask sddm.service || true
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
    # Start on a fresh line even if the file lacks a trailing newline.
    [[ -z $(tail -c1 /usr/lib/os-release) ]] || printf '\n' >>/usr/lib/os-release
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

# Zero-maintenance freshness: pull the latest available F44 package set
# from every enabled source (Fedora + Negativo17 + Terra + COPRs left
# enabled) so the image is never older than the current release tip.
# Runs after all installs so it also upgrades anything installed earlier
# in this layer. The floating :44 base-image tag already tracks the
# current ublue F44 build; this closes the gap to today's Fedora updates.
dnf5 -y --refresh upgrade

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
check 'swaylock theme' test -f /etc/skel/.config/swaylock/config
check 'theme tokens' test -f /usr/share/ryven/themes/navy.json
check 'no LIBVA_DRIVER_NAME=nvidia' bash -c '! grep -rE "^[[:space:]]*LIBVA_DRIVER_NAME=nvidia" /usr/share/sway /usr/lib/environment.d 2>/dev/null'
check 'wl-clipboard' rpm -q wl-clipboard
check 'dunst' rpm -q dunst
check 'wl-clip-persist' command -v wl-clip-persist
check 'greetd enabled' unit_enabled greetd.service
check 'oo7 daemon' test -x /usr/bin/oo7-daemon
check 'oo7 cli' command -v oo7-cli
check 'oo7 cargo credential' command -v cargo-credential-oo7
check 'oo7 pam module' test -f /usr/lib/security/pam_oo7.so
check 'oo7 portal' test -f /usr/share/xdg-desktop-portal/portals/oo7-portal.portal
check 'oo7 user unit' test -f /usr/lib/systemd/user/oo7-daemon.service
check 'oo7 user generator' test -x /usr/lib/systemd/user-generators/ryven-user-units
check 'keyring pam oneshot' unit_enabled ryven-keyring-pam.service
check 'no gnome-keyring' bash -c '! rpm -q gnome-keyring >/dev/null 2>&1'
check 'spell: hunspell+en variants' bash -c 'rpm -q hunspell hunspell-en hunspell-en-US hunspell-en-GB >/dev/null 2>&1'
check 'spell: hunspell-ar' rpm -q hunspell-ar
check 'spell: aspell-en' rpm -q aspell-en
check 'spell: gspell' rpm -q gspell
check 'c-ares' rpm -q c-ares
check 'ocr: tesseract+eng+ara' bash -c 'rpm -q tesseract tesseract-langpack-eng tesseract-langpack-ara >/dev/null 2>&1'
check 'screenshot-ocr helper' test -x /usr/local/bin/screenshot-ocr
check 'yazi' command -v yazi
check 'kde-connect' rpm -q kde-connect
check 'kdeconnect firewall' unit_enabled ryven-kdeconnect-firewall.service
check 'gvfs-mtp' rpm -q gvfs-mtp
check 'dns: cloudflare dot drop-in' grep -q 'DNSOverTLS=yes' /etc/systemd/resolved.conf.d/ryven-dns.conf
check 'dns: nm resolved backend' grep -q 'dns=systemd-resolved' /etc/NetworkManager/conf.d/ryven-dns.conf
check 'vm.max_map_count sysctl' grep -q 'vm.max_map_count = 2147483642' /etc/sysctl.d/90-ryven-max-map-count.conf
# Arch wiki Gaming -> Improving performance (integrated)
check 'tsc kargs' grep -q 'clocksource=tsc' /usr/lib/bootc/kargs.d/40-tsc-clocksource.toml
check 'gaming tmpfiles' test -f /etc/tmpfiles.d/ryven-gaming-response-time.conf
check 'thp always (proton)' grep -q 'transparent_hugepage/enabled - - - - always' /etc/tmpfiles.d/ryven-gaming-response-time.conf
check 'hugepages kargs' grep -q 'hugepages=1024' /usr/lib/bootc/kargs.d/50-hugepages.toml
check 'qdisc sysctl' grep -q 'fq_codel' /etc/sysctl.d/91-ryven-buffer-bloat.conf
check 'bbr sysctl' grep -q 'net.ipv4.tcp_congestion_control = bbr' /etc/sysctl.d/92-ryven-bbr.conf
check 'bbr in kernel' bash -c 'find /lib/modules -name "tcp_bbr*" -print -quit | grep -q . || grep -lq "^CONFIG_TCP_CONG_BBR=y" /boot/config-* 2>/dev/null'
check 'drirc vblank' grep -q 'vblank_mode' /etc/drirc
check 'pci latency oneshot' unit_enabled ryven-pci-latency.service
check 'setpci' command -v setpci
check 'nohang rpm' rpm -q nohang
check 'nohang enabled' unit_enabled nohang.service
check 'nohang conf' test -f /etc/nohang/nohang.conf
# Terra gaming/peripherals stack
check 'falcond rpm' rpm -q falcond
check 'falcond profiles' rpm -q falcond-profiles
check 'falcond config' test -f /etc/falcond/config.conf
check 'falcond template profile' test -f /usr/share/falcond/profiles/user/ryven-gaming-template.conf
check 'falcond enabled' unit_enabled falcond.service
check 'gamemode absent (falcond conflict)' bash -c '! rpm -q gamemode >/dev/null 2>&1'
check 'vicinae rpm' rpm -q vicinae
check 'vicinae user unit' test -f /usr/lib/systemd/user/vicinae.service
check 'lact rpm' rpm -q lact
check 'lactd enabled' unit_enabled lactd.service
check 'openrazer userspace' command -v openrazerd
check 'semanage' command -v semanage
check 'power-profiles-daemon' rpm -q power-profiles-daemon
check 'superfile (spf)' command -v spf
check 'betterbird binary' test -x /opt/betterbird/betterbird
check 'betterbird on PATH' command -v betterbird
check 'betterbird desktop entry' test -f /usr/share/applications/betterbird.desktop
check 'mise' command -v mise
check 'nvidia kargs' test -f /usr/lib/bootc/kargs.d/00-nvidia.toml
check 'nvidia-driver (neg17)' rpm -q nvidia-driver
check 'xorg-x11-nvidia (neg17)' rpm -q xorg-x11-nvidia
check 'nvidia-driver-libs (neg17)' rpm -q nvidia-driver-libs
check 'nvidia-driver-common (neg17)' rpm -q nvidia-driver-common
check 'nvidia-driver-cuda (neg17)' rpm -q nvidia-driver-cuda
check 'nvidia-driver-selinux (neg17)' rpm -q nvidia-driver-selinux
check 'libnvidia-fbc (neg17)' rpm -q libnvidia-fbc
check 'nvidia-settings' rpm -q nvidia-settings
check 'nvidia-smi' command -v nvidia-smi
check 'nvidia vulkan icd' test -f /usr/share/vulkan/icd.d/nvidia_icd.x86_64.json
check 'nvidia va api driver' test -f /usr/lib64/dri/nvidia_drv_video.so
check 'libva-nvidia-driver' rpm -q libva-nvidia-driver
check 'zswap kargs' test -f /usr/lib/bootc/kargs.d/10-zswap.toml
check 'ffmpeg rpm' rpm -q ffmpeg
check 'no docker' bash -c '! rpm -q docker >/dev/null 2>&1 && ! rpm -q docker-ce >/dev/null 2>&1'
if [[ ${fail} -ne 0 ]]; then
  die 'Ryven-Sericea invariant checks failed.'
fi
echo 'Ryven-Sericea invariant checks passed.'
