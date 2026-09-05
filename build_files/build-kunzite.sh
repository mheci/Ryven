#!/bin/bash
# Ryven-Kunzite (Hyprland) compose — thin image script over build_files/compose.sh.
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

apply_overlay system_files system_files_kunzite
lockdown_base_repos
dnf_speed_tweaks

bootstrap_fusion

bootstrap_terra

swap_kernel_cachyos

# NVIDIA stack + kmod: see install_nvidia_terra in compose.sh.
# BetterBird: host-fetched tarball, installed from the build context.
install_betterbird
install_nvidia_terra
install_priority egl-wayland

# Power management is tuned + tuned-ppd (preferred over the standalone
# power-profiles-daemon, which Conflicts with tuned-ppd's ppd-service).
# Swap a preinstalled standalone daemon out, then ensure the pair.
if have_rpm power-profiles-daemon && ! have_rpm tuned-ppd; then
  dnf5 -y swap power-profiles-daemon tuned-ppd || {
    dnf5 -y remove power-profiles-daemon
    dnf5 -y install tuned-ppd
  }
fi
install_priority tuned tuned-ppd
# thermald: Intel thermal daemon (DPTF/RAPL) for Intel laptops/handhelds;
# exits quietly without Intel thermal sensors, so enabling by default is safe.
install_priority thermald
systemctl enable thermald.service
dnf5 -y install \
  just mokutil shim efibootmgr \
  cryptsetup clevis clevis-luks clevis-dracut tpm2-tools \
  chrony podman podman-compose distrobox firewalld \
  git gh git-credential-libsecret \
  sudo-rs flatpak \
  greenboot greenboot-default-health-checks \
  keepassxc \
  pipewire pipewire-pulseaudio pipewire-alsa wireplumber \
  qt5-qtwayland qt6-qtwayland \
  xdg-utils xdg-user-dirs \
  NetworkManager-wifi NetworkManager-bluetooth NetworkManager-tui \
  nm-connection-editor network-manager-applet \
  blueman brightnessctl playerctl pavucontrol \
  thunar thunar-volman gvfs gvfs-mtp gvfs-smb gvfs-gphoto2 \
  libsecret polkit PackageKit \
  hunspell hunspell-en hunspell-en-US hunspell-en-GB hunspell-ar \
  aspell aspell-en gspell c-ares \
  tesseract tesseract-langpack-eng tesseract-langpack-ara \
  pciutils policycoreutils-python-utils \
  google-noto-sans-fonts rsms-inter-fonts jetbrains-mono-fonts \
  fontawesome-fonts

systemctl enable chronyd.service podman.socket firewalld.service NetworkManager.service
systemctl disable systemd-timesyncd.service 2>/dev/null || true
systemctl mask systemd-timesyncd.service 2>/dev/null || true
systemctl disable sshd.service 2>/dev/null || true
systemctl mask sshd.service 2>/dev/null || true

# First-party dev toolchain (official upstreams, never Terra): bun,
# opencode CLI + Desktop, system rustup stable, uv/uvx, mise, starship;
# npm/npx from Fedora.
install_bun_official
install_opencode_official
install_rustup_system
install_uv_official
install_mise_official
install_starship_official
install_any nodejs24-npm nodejs22-npm nodejs20-npm npm
# Pi coding agent (pi.dev), vendored from the CI-fetched npm stage; needs
# the nodejs+npm line above.
install_pi

install_priority deno
install_priority zed
install_priority mpv-nightly
install_ytdlp_latest
swap_ffmpeg_priority
install_steam
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
# Browsers (always latest): Firefox and Zen from their official upstream
# release tarballs, Brave Origin from its official GitHub release RPM
# (sha256-verified) — all host-fetched by ci/fetch-browsers.sh (betterbird
# pattern), installed from /ctx. No vendor repo is left enabled at rest
# (RC-1); freshness comes from the weekly image rebuild.
install_firefox
install_zen
install_brave_origin
install_gecko_policies
install_priority t3code
install_priority gpu-screen-recorder

# Hyprland latest: Terra/Fedora first, then isolated nett00n/hyprland (floating).
# Do not leave the COPR enabled on the booted image.
say 'hyprland stack (ladder first, nett00n COPR last-resort)'
missing_pkgs=(hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk hyprpaper hyprpicker hypridle hyprlock hyprcursor hyprpolkitagent hyprsunset hyprlauncher hyprsysteminfo hyprland-qt-support hyprqt6engine hyprpwcenter hyprshutdown hyprshot hyprtoolkit quickshell uwsm)
for pass in 1 2; do
  still_missing=()
  for pkg in "${missing_pkgs[@]}"; do
    if have_rpm "${pkg}"; then continue; fi
    if _q dnf5 -y install --skip-broken --skip-unavailable "${TERRA_REPOS[@]/#/--enablerepo=}" "${FUSION_REPOS[@]/#/--enablerepo=}" "${pkg}" && have_rpm "${pkg}"; then
      echo "pkg: ${pkg} (terra/fusion)"; continue
    fi
    if _q dnf5 -y install --skip-broken --skip-unavailable "${pkg}" && have_rpm "${pkg}"; then echo "pkg: ${pkg} (fedora)"; continue; fi
    still_missing+=("${pkg}")
  done
  missing_pkgs=("${still_missing[@]}")
  if ((pass == 1 && ${#missing_pkgs[@]})); then
    echo "hyprland ladder pass 1 missed ${#missing_pkgs[@]} pkg(s), cleaning metadata and retrying" >&2
    dnf5 clean metadata >/dev/null 2>&1 || true
    sleep 20
  fi
done
if ((${#missing_pkgs[@]})); then
  echo "hyprland COPR set: ${missing_pkgs[*]}"
  dnf5 -y copr enable nett00n/hyprland >>/tmp/compose-last.log 2>&1 ||
    die 'hyprland COPR enable failed'
  dnf5 clean metadata >/dev/null 2>&1 || true
  _q dnf5 -y install --skip-broken --skip-unavailable "${missing_pkgs[@]}" || true
  still_missing=()
  for pkg in "${missing_pkgs[@]}"; do
    if have_rpm "${pkg}"; then
      echo "pkg: ${pkg} (copr)"
    elif _q dnf5 -y install --skip-broken --skip-unavailable "${pkg}" && have_rpm "${pkg}"; then
      echo "pkg: ${pkg} (copr-retry)"
    else
      still_missing+=("${pkg}")
    fi
  done
  missing_pkgs=("${still_missing[@]}")
  dnf5 -y copr disable nett00n/hyprland >/dev/null 2>&1 || true
  if ((${#missing_pkgs[@]})); then
    echo "--- no provider for: ${missing_pkgs[*]}; log tail: ---" >&2
    tail -n 25 /tmp/compose-last.log >&2 || true
    die "hyprland stack incomplete: ${missing_pkgs[*]}"
  fi
fi
have_rpm hyprland || die 'hyprland RPM missing'
have_rpm quickshell || die 'quickshell RPM missing'

# Must-have Wayland utilities (wiki + requested clipboard stack).
install_priority \
  wl-clipboard dunst grim slurp fuzzel satty cliphist \
  kde-connect \
  wf-recorder \
  android-tools libimobiledevice
# yazi is not in the Fedora repos; it comes from Terra (weekly rebuild
# tracks the Terra package; repo is disabled at rest by the Terra bootstrap).
install_priority yazi
# nohang (Terra; not in Fedora): PSI-based low-memory handler that kills
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
install_wl_clip_persist
# oo7 replaces gnome-keyring as the Secret Service keyring (see compose.sh).
install_oo7
if ! install_any greetd; then
  die 'greetd missing'
fi
# tuigreet is the configured greeter command in system_files_kunzite greetd config;
# a missing binary means no graphical login, so this is fatal like Sericea.
install_any tuigreet greetd-tuigreet || die 'tuigreet/greetd-tuigreet missing: greetd would have no greeter'

if have_rpm zram-generator-defaults || have_rpm zram-generator; then
  dnf5 -y remove zram-generator-defaults zram-generator
fi
mkdir -p /usr/lib/systemd /etc/systemd/system
printf '%s\n' '# Ryven-Kunzite: zram disabled. Compressed RAM is zswap.' \
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
    -e 's/^NAME=.*/NAME="Ryven Kunzite"/' \
    -e 's/^PRETTY_NAME=.*/PRETTY_NAME="Ryven Kunzite (Hyprland)"/' \
    /usr/lib/os-release
  # Unique per build: IMAGE_ID decides whether a hibernation image may be
  # resumed, so a constant would risk resuming a stale image after upgrade.
  build_id="ryven-kunzite-$(date -u +%Y%m%d%H%M%S)"
  if grep -q '^VARIANT_ID=' /usr/lib/os-release; then
    sed -i 's/^VARIANT_ID=.*/VARIANT_ID="ryven-kunzite"/' /usr/lib/os-release
  else
    [[ -z $(tail -c1 /usr/lib/os-release) ]] || printf '\n' >>/usr/lib/os-release
    echo 'VARIANT_ID="ryven-kunzite"' >>/usr/lib/os-release
  fi
  if grep -q '^IMAGE_ID=' /usr/lib/os-release; then
    sed -i "s/^IMAGE_ID=.*/IMAGE_ID=\"${build_id}\"/" /usr/lib/os-release
  else
    # Start on a fresh line even if the file lacks a trailing newline.
    [[ -z $(tail -c1 /usr/lib/os-release) ]] || printf '\n' >>/usr/lib/os-release
    echo "IMAGE_ID=\"${build_id}\"" >>/usr/lib/os-release
  fi
fi
mkdir -p /etc/default/grub.d
cat >/etc/default/grub.d/50-ryven.cfg <<'EOF'
GRUB_DISTRIBUTOR="Ryven Kunzite"
EOF

# Ship Hyprland/QuickShell defaults into skel and XDG. Fail with a clear
# message when an expected source file moved instead of a bare cp error.
require_src /usr/share/hypr/hyprland.conf
require_src /usr/share/hypr/hyprpaper.conf
require_src /usr/share/hypr/hypridle.conf
require_src /usr/share/hypr/hyprlock.conf
require_src /etc/xdg/quickshell/shell.qml
require_src /etc/xdg/quickshell/ryven/Bar.qml
require_src /etc/xdg/quickshell/AGENTS.md
compgen -G '/usr/share/hypr/*.conf' >/dev/null || die 'no Hyprland configs under /usr/share/hypr'
mkdir -p /etc/skel/.config/hypr /etc/skel/.config/quickshell /etc/xdg/hypr
cp -a /usr/share/hypr/hyprland.conf /etc/skel/.config/hypr/hyprland.conf
cp -a /usr/share/hypr/hyprpaper.conf /etc/skel/.config/hypr/hyprpaper.conf
cp -a /usr/share/hypr/hypridle.conf /etc/skel/.config/hypr/hypridle.conf
cp -a /usr/share/hypr/hyprlock.conf /etc/skel/.config/hypr/hyprlock.conf
cp -a /etc/xdg/quickshell/. /etc/skel/.config/quickshell/
cp -a /usr/share/hypr/*.conf /etc/xdg/hypr/

mkdir -p /etc/xdg/uwsm
cat >/etc/xdg/uwsm/env-hyprland <<'EOF'
export NVD_BACKEND=direct
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export ELECTRON_OZONE_PLATFORM_HINT=auto
EOF

install_priority mangohud uupd topgrade ananicy-cpp cachyos-ananicy-rules bpftune-gaming
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
apply_overlay system_files system_files_kunzite

# First-boot Flathub oneshot (DistroShelf + flatpak management OOTBE).
install_flatpak_firstboot \
  com.ranfdev.DistroShelf \
  io.github.flattool.Warehouse \
  com.github.tchx84.Flatseal

final_cleanup
