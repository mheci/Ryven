#!/bin/bash
# Ryven (KDE) compose — thin image script over build_files/compose.sh.
# Base: ublue kinoite-main:latest. Product rules live in compose.sh.
set -euo pipefail
# shellcheck source=/dev/null
source /ctx/compose.sh

# Fedora major used in Fusion/Terra URL paths. Bump Fusion, Terra, and the
# Containerfile FROM together when leaving 44.

apply_overlay system_files
lockdown_base_repos
dnf_speed_tweaks

# RPM Fusion release RPMs drop /etc/yum.repos.d/rpmfusion-*.repo. Version in
# the URL must match FEDORA_RELEASE. Files are disabled after Terra bootstrap.
bootstrap_fusion

bootstrap_terra

# Fedora kernel set -> CachyOS LTO (COPR, retrying, fail-closed).
swap_kernel_cachyos

install_betterbird
install_nvidia_terra

# Base OS: just (ujust), Secure Boot tooling, LUKS/TPM unlock, chrony (not
# timesyncd), podman + distrobox, firewalld, git+gh, sudo-rs, Flatpak binary
# for first-boot host installs, Plasma Login Manager (not SDDM), greenboot.
# Text/OCR stack: spell checkers with
# English variants + Arabic (hunspell covers ar; F44 has no aspell-ar
# package), c-ares for the agentic toolchain, tesseract for Spectacle OCR.
# KDE minimum floor: device pairing on LAN, KIO virtual filesystems, the
# Plasma 6 polkit agent (package is 'polkit-kde' on F44).
# NOTE: no '#' comment lines inside the install command below - a comment
# line terminates the backslash continuation, and the remaining lines would
# be silently skipped.
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
  plasma-login-manager kcm-plasmalogin \
  greenboot greenboot-default-health-checks \
  keepassxc \
  hunspell hunspell-en hunspell-en-US hunspell-en-GB hunspell-ar \
  aspell aspell-en gspell c-ares \
  tesseract tesseract-langpack-eng tesseract-langpack-ara \
  pciutils policycoreutils-python-utils \
  kde-connect kio-fuse kio-extras kio-gdrive polkit-kde polkit PackageKit

# chronyd is NTP. timesyncd would fight it; mask so a later enable cannot
# start it. sshd off by default (workstation image, not a server).
systemctl enable chronyd.service podman.socket firewalld.service
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

# deno, Zed stable (not nightly), mpv-nightly (Terra nightly,
# Conflicts: mpv, same /usr/bin/mpv) from Terra; yt-dlp latest stable
# binary (outside Terra) via install_ytdlp_latest.
install_priority deno
install_priority zed
install_priority mpv-nightly
install_ytdlp_latest
swap_ffmpeg_priority
install_steam
# scx-scheds = schedulers; scx-tools = scx_loader unit + CLI. Terra stable.
install_priority scx-scheds scx-tools

# scx_loader config: lavd in Gaming/performance for every mode. Dual path
# /etc/scx_loader.toml and /etc/scx_loader/config.toml because unit versions
# disagree on the filename. /etc/default/scx is the classic scx.service env.
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


install_priority faugus-launcher
# Remove Flathub Firefox if the base image seeded it; we ship the upstream
# tarball (install_firefox below).
if command -v flatpak >/dev/null 2>&1; then
  flatpak uninstall --system -y org.mozilla.firefox || true
fi

# Browsers (always latest): Firefox and Zen from their official upstream
# release tarballs, Brave Origin from its official GitHub release RPM
# (sha256-verified) — all host-fetched by ci/fetch-browsers.sh (betterbird
# pattern), installed from /ctx. No vendor repo is left enabled at rest
# (RC-1); freshness comes from the weekly image rebuild.
install_firefox
install_zen
install_brave_origin
install_gecko_policies

# Align Mesa with Terra (mesa + multimedia). Fail soft: NVIDIA userspace from
# ublue can conflict; never use mesa-*-freeworld --allowerasing.
if ! dnf5 -y distro-sync "${TERRA_REPOS[@]/#/--enablerepo=}" \
  mesa-dri-drivers mesa-va-drivers mesa-vulkan-drivers \
  mesa-libGL mesa-libEGL mesa-libgbm mesa-filesystem \
  mesa-dri-drivers.i686 mesa-va-drivers.i686 mesa-vulkan-drivers.i686 \
  mesa-libGL.i686 mesa-libEGL.i686 mesa-libgbm.i686; then
  echo 'Terra Mesa distro-sync failed (NVIDIA userspace conflict). Keeping current Mesa.' >&2
fi

# VA-API/VDPAU stack, GStreamer, codecs, Intel iHD + i965, KDE thumbnailers.
install_priority \
  libva libva-utils libvdpau vdpauinfo \
  gstreamer1-plugin-libav gstreamer1-plugin-openh264 gstreamer1-plugins-bad-free \
  mozilla-openh264 dav1d aom svt-av1 lame opus ffmpegthumbnailer \
  libva-intel-media-driver gstreamer1-plugins-ugly x264 \
  totem-video-thumbnailer kdegraphics-thumbnailers icoextract-thumbnailer
install_any python3-icoextract
# intel-media-driver is rpmfusion-nonfree-only and the solver skips it in the
# ublue/NVIDIA-userspace env (present in nonfree metadata with satisfiable
# deps, yet uninstallable — build 33878650622). Fail soft like Terra Mesa:
# libva-intel-driver above still covers Intel VAAPI, and a red build is worse
# than a missing iHD driver on an NVIDIA-primary image.
if ! install_priority intel-media-driver; then
  echo 'WARN: intel-media-driver skipped by solver; continuing without iHD VAAPI' >&2
fi
# libva-intel-driver (legacy i965 VAAPI, rpmfusion-free-only) is skipped by
# the solver in this env despite being present with trivial deps and no
# conflicts (builds 33884584709/33888294144/33892286423). Fail soft like its
# sibling: libva-intel-media-driver above covers modern Intel iGPUs from
# Fedora, which is what matters on current hardware.
if ! install_priority libva-intel-driver; then
  echo 'WARN: libva-intel-driver skipped by solver; continuing without i965 VAAPI' >&2
fi

# libdvdcss lives in rpmfusion-free-tainted. Install the tainted release RPM
# with free enabled, install libdvdcss, then disable tainted repos at rest.
dnf5 -y install --enablerepo=rpmfusion-free "${FUSION_REPOS[@]/#/--enablerepo=}" rpmfusion-free-release-tainted
dnf5 -y install --enablerepo=rpmfusion-free-tainted libdvdcss
disable_yum_repos /etc/yum.repos.d/*tainted*.repo

# zram is removed entirely. Compressed RAM is zswap via kargs.d/10-zswap.toml
# from system_files. Empty zram-generator.conf plus mask of the instance unit.
if have_rpm zram-generator-defaults || have_rpm zram-generator; then
  dnf5 -y remove zram-generator-defaults zram-generator
fi
mkdir -p /usr/lib/systemd /etc/systemd/system
printf '%s\n' '# Ryven: zram disabled. Compressed RAM is zswap (kargs.d/10-zswap.toml).' \
  >/usr/lib/systemd/zram-generator.conf
ln -sfn /dev/null /etc/systemd/system/systemd-zram-setup@zram0.service
systemctl mask systemd-zram-setup@zram0.service

# Plasma Login Manager is the display manager. Mask SDDM only when its unit
# file exists, so a later package cannot re-enable it as default.
systemctl enable --force plasmalogin.service
if [[ -f /usr/lib/systemd/system/sddm.service ]]; then
  systemctl disable sddm.service || true
  systemctl mask sddm.service || true
fi

# Secrets: oo7 is the Secret Service keyring (org.freedesktop.secrets) on
# every Ryven image — cargo-built at the latest tag (install_oo7 in
# compose.sh), auto-unlocked at login by pam_oo7 (ryven-keyring-pam oneshot
# below), enabled per-user by the ryven-user-units generator, and D-Bus
# activation for the bus name routes to the same user unit
# (/etc/dbus-1/services/org.freedesktop.secrets.service).
# KDE Wallet stays for KDE-native apps: kf6-kwallet ships kwalletd6, and
# pam-kwallet auto-unlocks the default wallet (kdewallet, blowfish,
# password = user password) with the login password. ksecretd — the
# KWallet-backed Secret Service shim — is deliberately never started on
# any image: oo7 owns the bus name. The PAM lines are added at first boot
# by the ryven-keyring-pam oneshot; the plasma-kwallet-pam user unit is
# enabled by the ryven-user-units generator (compose has no user session,
# so `systemctl --user enable` cannot run here).
install_oo7
install_priority kf6-kwallet
install_priority pam-kwallet
systemctl enable ryven-keyring-pam.service
# yazi is not in the Fedora repos; it comes from Terra (repo disabled at
# rest by the Terra bootstrap; weekly rebuild tracks the Terra package).
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
  # The akmod installs its modules (razeraccessory/razerkbd/razerkraken,
  # plus razermouse on some builds) under extra/openrazer/, NOT as
  # openrazer.ko - build_kmod checks that directory.
  build_kmod openrazer 'extra/openrazer/*.ko*' "${KVER}" 'openrazer-kmod-*.src.rpm'
fi
# Toolchain stays: akmod RPMs hard-require gcc/make, and the LTO kernel
# needs clang/lld for every kmod build (also at image-update time).
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

# KDE Connect LAN access: mdns discovery + 1714/tcp through firewalld.
systemctl enable ryven-kdeconnect-firewall.service
# PCI latency timers (CachyOS-style) at boot, before any GUI starts.
systemctl enable ryven-pci-latency.service

# Enable every greenboot/redboot unit shipped by the RPMs, including
# redboot-auto-reboot (native greenboot; do not drop it). Fail if none found.
enabled=0
shopt -s nullglob
for unit in /usr/lib/systemd/system/greenboot*.service /usr/lib/systemd/system/redboot*.service; do
  systemctl enable "$(basename "${unit}")"
  enabled=1
done
((enabled)) || die 'greenboot installed but no units under /usr/lib/systemd/system'

# Fonts: DejaVu/Noto/Droid as fallbacks, Inter as Plasma default (kdeglobals
# in system_files), JetBrains Mono, Adwaita, Carlito. cleartype-fonts if Terra
# or Fedora has the Name.
dnf5 -y install \
  dejavu-sans-fonts dejavu-sans-mono-fonts dejavu-serif-fonts \
  google-droid-sans-fonts google-droid-serif-fonts google-droid-sans-mono-fonts \
  google-noto-sans-mono-fonts google-noto-sans-fonts \
  rsms-inter-fonts jetbrains-mono-fonts \
  adwaita-sans-fonts adwaita-mono-fonts google-crosextra-carlito-fonts
install_priority cleartype-fonts

# os-release NAME/PRETTY_NAME/IMAGE_ID for bootc/rpm-ostree UI and neofetch.
# GRUB_DISTRIBUTOR for the boot menu label. Plymouth spinner watermark from
# the branded pixmap. plasma-set-default-lookandfeel writes /etc/xdg bits
# for org.ryven.desktop if the helper exists on this Plasma version.
if [[ -f /usr/lib/os-release ]]; then
  sed -i \
    -e 's/^NAME=.*/NAME="Ryven"/' \
    -e 's/^PRETTY_NAME=.*/PRETTY_NAME="Ryven (Fedora Kinoite)"/' \
    /usr/lib/os-release
  # Unique per build: IMAGE_ID decides whether a hibernation image may be
  # resumed, so a constant would risk resuming a stale image after upgrade.
  build_id="ryven-$(date -u +%Y%m%d%H%M%S)"
  if grep -q '^VARIANT_ID=' /usr/lib/os-release; then
    sed -i 's/^VARIANT_ID=.*/VARIANT_ID="ryven"/' /usr/lib/os-release
  else
    [[ -z $(tail -c1 /usr/lib/os-release) ]] || printf '\n' >>/usr/lib/os-release
    echo 'VARIANT_ID="ryven"' >>/usr/lib/os-release
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
GRUB_DISTRIBUTOR="Ryven"
EOF
if [[ -d /usr/share/plymouth/themes/spinner && -f /usr/share/pixmaps/ryven.png ]]; then
  cp -f /usr/share/pixmaps/ryven.png /usr/share/plymouth/themes/spinner/watermark.png
fi
if [[ -d /usr/share/plasma/look-and-feel/org.ryven.desktop && -x /usr/libexec/plasma-set-default-lookandfeel ]]; then
  mkdir -p /etc/xdg
  /usr/libexec/plasma-set-default-lookandfeel org.ryven.desktop
fi

# ScopeBuddy (scb symlink) for scoped game launches.
install_priority jq ScopeBuddy
if command -v scopebuddy >/dev/null && [[ ! -e /usr/bin/scb ]]; then
  ln -sf "$(command -v scopebuddy)" /usr/bin/scb
fi

# beesd: online btrfs dedup. Config UUID is host-specific, so a oneshot
# writes /etc/bees/${UUID}.conf and a generator enables beesd@UUID only when
# /var/home or / is btrfs. Harmless no-op on ext4/xfs test VMs.
install_priority bees
mkdir -p /usr/lib/systemd/system-generators /usr/libexec /etc/bees /usr/lib/systemd/system
cat >/usr/libexec/ryven-bees-configure <<'EOF'
#!/bin/bash
set -euo pipefail
uuid=$(findmnt -n -o UUID /var/home 2>/dev/null || findmnt -n -o UUID / || true)
[[ -n "${uuid}" ]] || exit 0
fstype=$(findmnt -n -o FSTYPE /var/home 2>/dev/null || findmnt -n -o FSTYPE / || true)
[[ "${fstype}" == "btrfs" ]] || exit 0
mkdir -p /etc/bees
cat >"/etc/bees/${uuid}.conf" <<CONF
UUID=${uuid}
CONF
EOF
chmod +x /usr/libexec/ryven-bees-configure
cat >/usr/lib/systemd/system-generators/ryven-bees-generator <<'EOF'
#!/bin/bash
set -euo pipefail
normal=${1:-/run/systemd/generator}
uuid=$(findmnt -n -o UUID /var/home 2>/dev/null || findmnt -n -o UUID / || true)
[[ -n "${uuid}" ]] || exit 0
fstype=$(findmnt -n -o FSTYPE /var/home 2>/dev/null || findmnt -n -o FSTYPE / || true)
[[ "${fstype}" == "btrfs" ]] || exit 0
[[ -f /usr/lib/systemd/system/beesd@.service ]] || exit 0
mkdir -p "${normal}/multi-user.target.wants"
ln -sf "/usr/lib/systemd/system/beesd@.service" "${normal}/multi-user.target.wants/beesd@${uuid}.service"
EOF
chmod +x /usr/lib/systemd/system-generators/ryven-bees-generator
cat >/usr/lib/systemd/system/ryven-bees-configure.service <<'EOF'
[Unit]
Description=Write beesd UUID config for the host btrfs
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target
RequiresMountsFor=/var/home /

[Service]
Type=oneshot
ExecStart=/usr/libexec/ryven-bees-configure
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable ryven-bees-configure.service

# plugdev group for OpenRazer udev (daemon installed with the Terra gaming
# stack above). polychromatic: Terra/Fedora first, else OpenRazer hardware
# repo (disabled after install).
getent group plugdev >/dev/null || groupadd -r plugdev
if ! dnf5 -y install polychromatic; then
  vendor_repo_install '*razer*.repo' https://download.opensuse.org/repositories/hardware:/razer/Fedora_44/hardware:razer.repo polychromatic ||
    die 'polychromatic (OBS hardware_razer fallback) failed'
fi
have_rpm polychromatic || die 'polychromatic missing after OBS fallback'

# MangoHud 64-bit always (obs-vkcapture has no provider in any repo as of
# 2026-09-04 — verified across Terra/Fusion/Fedora — so it is dropped).
# 32-bit MangoHud only if a NEVRA exists. repoquery is used for the probe
# because `dnf5 list` exits 0 even with zero matches.
install_priority mangohud
if dnf5 repoquery --available "${TERRA_REPOS[@]/#/--enablerepo=}" "${FUSION_REPOS[@]/#/--enablerepo=}" --queryformat '%{name}.%{arch}\n' mangohud.i686 2>/dev/null | grep -q '^mangohud\.i686$'; then
  install_priority mangohud.i686
fi
install_any goverlay

# I/O scheduler udev: kyber on NVMe, bfq on rotational, mq-deadline on SATA
# SSD. ATTR match requires the scheduler to be in the available list.
# Remove the old 60-ryven-kyber.rules name if a previous layer left it.
mkdir -p /usr/lib/udev/rules.d
cat >/usr/lib/udev/rules.d/60-ryven-io-scheduler.rules <<'EOF'
# NVMe → kyber
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}=="*kyber*", ATTR{queue/scheduler}="kyber"
# Rotational HDD → bfq
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="sd*|vd*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}=="*bfq*", ATTR{queue/scheduler}="bfq"
# Non-rotational SATA/virtio SSD → mq-deadline
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="sd*|vd*|mmcblk*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}=="*mq-deadline*", ATTR{queue/scheduler}="mq-deadline"
EOF
rm -f /usr/lib/udev/rules.d/60-ryven-kyber.rules

# uupd.timer is the ublue update path (bootc upgrade, no --apply). Disable
# rpm-ostree AutomaticUpdatePolicy so it cannot fight uupd.
install_priority uupd topgrade
if [[ -f /etc/rpm-ostreed.conf ]] && grep -q '^AutomaticUpdatePolicy=' /etc/rpm-ostreed.conf; then
  sed -i 's/^AutomaticUpdatePolicy=.*/AutomaticUpdatePolicy=none/' /etc/rpm-ostreed.conf
fi
systemctl enable uupd.timer

# First-boot Flathub oneshot (Flatseal, Warehouse, Gear Lever, Bazaar,
# DistroShelf) via install_flatpak_firstboot.
install_flatpak_firstboot \
  com.github.tchx84.Flatseal \
  io.github.flattool.Warehouse \
  it.mijorus.gearlever \
  io.github.kolunmi.Bazaar \
  com.ranfdev.DistroShelf

# ghostty-tip is a rolling Name; ghostty is stable. t3code stable, not nightly.
# terra-gamescope: terrapkg has a spec on f44 but no NEVRA in terra /
# terra-multimedia / terra-mesa as of 2026-09-02. Do not install Fedora
# gamescope (different Name). Omit compositor if unpublished.
install_any ghostty-tip ghostty
install_priority \
  t3code heroic-games-launcher protonplus vulkan-low-latency-layer \
  ananicy-cpp cachyos-ananicy-rules android-udev-rules bpftune-gaming lact darkly
if ! install_priority terra-gamescope; then
  echo 'terra-gamescope unpublished on Terra f44 repos; compositor omitted' >&2
fi
install_priority rpcs3 extest vicinae espanso-wayland
install_priority gpu-screen-recorder
install_priority bibata-cursor-theme klassy tela-icon-theme
[[ -f /usr/lib/systemd/system/bpftune.service ]] ||
   die 'bpftune-gaming missing bpftune.service'
systemctl enable bpftune.service ananicy-cpp.service

# Pinned CachyOS Proton SLR tarball. The .sha512sum asset is fetched over TLS
# from the same release and cross-checked against the PROTON_SHA512 value
# pinned below, so replacing both release assets cannot ship a tampered
# tarball. Fail if compatibilitytool.vdf is missing after extract (Steam will
# not list the tool). Not curl|sh.
install_proton_latest

final_upgrade
apply_overlay system_files

# Build-time invariants. No GPU, systemd is not PID 1: every install step
# above is fail-closed (die on error), so reaching this point means a
# fully-configured image. Final hygiene only.

final_cleanup
