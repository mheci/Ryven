#!/bin/bash
# Ryven-WL (Hyprland) compose — thin image script over build_files/compose.sh.
# Base: ublue base-main:latest. Product rules live in compose.sh.
set -euo pipefail
# shellcheck source=/dev/null
source /ctx/compose.sh

# The ublue base image ships /usr/local as a placeholder in a
# non-directory form (a dangling symlink in base-main: `[[ -e ]]` is false
# but `cp -avf` still refuses to lay a directory over it). Replace it in
# any non-directory form before the copy.
if [[ ! -d /usr/local ]]; then
  rm -rf /usr/local
fi

apply_overlay system_files system_files_wl
lockdown_base_repos

bootstrap_fusion

bootstrap_terra

swap_kernel_cachyos

# NVIDIA stack + kmod: see install_nvidia_terra in compose.sh.
# BetterBird: host-fetched tarball, installed from the build context.
# system_files.
install_betterbird
install_nvidia_terra
install_priority egl-wayland

# The base image bundles tuned; its tuned-ppd subpackage provides
# ppd-service, which Conflicts with power-profiles-daemon (our power
# manager, pinned by an invariant). Drop tuned-ppd before the install.
if have_rpm tuned-ppd; then
  dnf5 -y remove tuned-ppd
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

install_priority mise

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


install_any ghostty-tip ghostty
install_any helium-browser-bin helium-browser
install_priority t3code opencode-cli
install_priority gpu-screen-recorder

# Hyprland latest: Terra/Fedora first, then isolated nett00n/hyprland (floating).
# Do not leave the COPR enabled on the booted image.
say 'hyprland stack (ladder first, nett00n COPR last-resort)'
missing_pkgs=()
for pkg in hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk hyprpaper hyprpicker hypridle hyprlock hyprcursor hyprpolkitagent hyprsunset hyprlauncher hyprsysteminfo hyprland-qt-support hyprqt6engine hyprpwcenter hyprshutdown hyprshot hyprtoolkit quickshell uwsm; do
  if have_rpm "${pkg}"; then continue; fi
  if _q dnf5 -y install "${TERRA_REPOS[@]/#/--enablerepo=}" "${FUSION_REPOS[@]/#/--enablerepo=}" "${pkg}"; then
    echo "pkg: ${pkg} (terra/fusion)"; continue
  fi
  if _q dnf5 -y install "${pkg}"; then echo "pkg: ${pkg} (fedora)"; continue; fi
  missing_pkgs+=("${pkg}")
done
if ((${#missing_pkgs[@]})); then
  copr_install_isolated nett00n/hyprland "${missing_pkgs[@]}" || die 'hyprland COPR fallback failed'
fi
have_rpm hyprland || die 'hyprland RPM missing'
have_rpm quickshell || die 'quickshell RPM missing'

# Must-have Wayland utilities (wiki + requested clipboard stack).
install_priority \
  wl-clipboard dunst grim slurp fuzzel \
  kde-connect \
  wf-recorder \
  android-tools libimobiledevice
# yazi is not in the Fedora 44 repos; it comes from Terra (weekly rebuild
# tracks the Terra package; repo is disabled at rest by the Terra bootstrap).
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
  build_kmod openrazer 'extra/openrazer/*.ko*' "${KVER}" 'openrazer-kmod-*.src.rpm'
fi
# The build toolchain (gcc/make/clang/llvm/lld + kernel-devel) STAYS in
# Toolchain stays: akmods need gcc/make; the LTO kernel needs clang/lld,
# also for kmod rebuilds at image-update time.
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
install_wl_clip_persist
# oo7 replaces gnome-keyring as the Secret Service keyring (see compose.sh).
install_oo7
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

install_proton_latest

final_upgrade
apply_overlay system_files system_files_wl

smoke 'hyprland rpm' rpm -q hyprland
smoke 'master layout' grep -q 'layout = master' /usr/share/hypr/hyprland.conf
smoke 'tearing' grep -q 'allow_tearing = true' /usr/share/hypr/hyprland.conf
smoke 'navy borders' grep -q 'col.active_border = rgba(778da9ee)' /usr/share/hypr/hyprland.conf
smoke 'hyprlock theme' grep -q 'text-color = e0e1dd' /usr/share/hypr/hyprlock.conf
smoke 'wl-clip-persist' command -v wl-clip-persist
smoke 'greetd enabled' unit_enabled greetd.service
smoke 'oo7 daemon' test -x /usr/bin/oo7-daemon
smoke 'oo7 pam module' test -f /usr/lib/security/pam_oo7.so
smoke 'yazi' command -v yazi
smoke 'dns: cloudflare dot drop-in' grep -q 'DNSOverTLS=yes' /etc/systemd/resolved.conf.d/ryven-dns.conf
smoke 'dns: nm resolved backend' grep -q 'dns=systemd-resolved' /etc/NetworkManager/conf.d/ryven-dns.conf
smoke 'vm.max_map_count sysctl' grep -q 'vm.max_map_count = 2147483642' /etc/sysctl.d/90-ryven-max-map-count.conf
smoke 'tsc kargs' grep -q 'clocksource=tsc' /usr/lib/bootc/kargs.d/40-tsc-clocksource.toml
smoke 'gaming tmpfiles' test -f /etc/tmpfiles.d/ryven-gaming-response-time.conf
smoke 'thp always (proton)' grep -q 'transparent_hugepage/enabled - - - - always' /etc/tmpfiles.d/ryven-gaming-response-time.conf
smoke 'hugepages kargs' grep -q 'hugepages=1024' /usr/lib/bootc/kargs.d/50-hugepages.toml
smoke 'qdisc sysctl' grep -q 'fq_codel' /etc/sysctl.d/91-ryven-buffer-bloat.conf
smoke 'bbr sysctl' grep -q 'net.ipv4.tcp_congestion_control = bbr' /etc/sysctl.d/92-ryven-bbr.conf
smoke 'bbr in kernel' bash -c 'find /lib/modules -name "tcp_bbr*" -print -quit | grep -q . || grep -lq "^CONFIG_TCP_CONG_BBR=y" /boot/config-* 2>/dev/null'
smoke 'drirc vblank' grep -q 'vblank_mode' /etc/drirc
smoke 'pci latency oneshot' unit_enabled ryven-pci-latency.service
smoke 'nohang rpm' rpm -q nohang
smoke 'nohang enabled' unit_enabled nohang.service
smoke 'falcond rpm' rpm -q falcond
smoke 'falcond profiles' rpm -q falcond-profiles
smoke 'falcond config' test -f /etc/falcond/config.conf
smoke 'falcond template profile' test -f /usr/share/falcond/profiles/user/ryven-gaming-template.conf
smoke 'falcond enabled' unit_enabled falcond.service
smoke 'gamemode absent (falcond conflict)' bash -c '! rpm -q gamemode >/dev/null 2>&1'
smoke 'vicinae rpm' rpm -q vicinae
smoke 'lact rpm' rpm -q lact
smoke 'openrazer userspace' command -v openrazerd
smoke 'power-profiles-daemon' rpm -q power-profiles-daemon
smoke 'betterbird binary' test -x /opt/betterbird/betterbird
smoke 'betterbird on PATH' command -v betterbird
smoke 'mise' command -v mise
smoke 'nvidia kargs' test -f /usr/lib/bootc/kargs.d/00-nvidia.toml
smoke 'nvidia-settings' rpm -q nvidia-settings
smoke 'nvidia-smi' command -v nvidia-smi
smoke 'zswap kargs' test -f /usr/lib/bootc/kargs.d/10-zswap.toml
smoke 'ffmpeg rpm' rpm -q ffmpeg
smoke 'no docker' bash -c '! rpm -q docker >/dev/null 2>&1 && ! rpm -q docker-ce >/dev/null 2>&1'
smoke 'kernel singleton' bash -c '[[ $(ls /usr/lib/modules | wc -l) == 1 ]]'
smoke 'nvidia kmod present' bash -c 'find /usr/lib/modules -name "nvidia*.ko*" -print -quit | grep -q .'
smoke 'tuigreet' command -v tuigreet
smoke_done
