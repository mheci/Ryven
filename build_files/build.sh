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

# RPM Fusion release RPMs drop /etc/yum.repos.d/rpmfusion-*.repo. Version in
# the URL must match FEDORA_RELEASE. Files are disabled after Terra bootstrap.
bootstrap_fusion

bootstrap_terra

# Fedora kernel set -> CachyOS LTO (COPR, retrying, fail-closed).
swap_kernel_cachyos

install_betterbird
install_nvidia_terra

# Base OS: just (ujust), Secure Boot tooling, LUKS/TPM unlock, chrony (not
# timesyncd), podman (not docker), firewalld, git+gh, sudo-rs, Flatpak binary
# for first-boot host installs, Plasma Login Manager (not SDDM), greenboot,
# Firefox RPM (not the Flathub app). Text/OCR stack: spell checkers with
# English variants + Arabic (hunspell covers ar; F44 has no aspell-ar
# package), c-ares for the agentic toolchain, tesseract for Spectacle OCR.
# KDE minimum floor: device pairing on LAN, KIO virtual filesystems, the
# Plasma 6 polkit agent (package is 'polkit-kde' on F44).
# NOTE: no '#' comment lines inside the install command below - a comment
# line terminates the backslash continuation, and the remaining lines would
# execute as their own command (observed: 'hunspell' run as a binary).
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
  plasma-login-manager kcm-plasmalogin \
  greenboot greenboot-default-health-checks \
  firefox \
  hunspell hunspell-en hunspell-en-US hunspell-en-GB hunspell-ar \
  aspell aspell-en gspell c-ares \
  tesseract tesseract-langpack-eng tesseract-langpack-ara \
  pciutils policycoreutils-python-utils power-profiles-daemon \
  kde-connect kio-fuse kio-extras kio-gdrive polkit-kde

# Product rule: no Docker engine on the image.
if have_rpm docker-ce || have_rpm docker; then
  die 'docker RPM must not be present'
fi

# chronyd is NTP. timesyncd would fight it; mask so a later enable cannot
# start it. sshd off by default (workstation image, not a server).
systemctl enable chronyd.service podman.socket firewalld.service
systemctl disable systemd-timesyncd.service 2>/dev/null || true
systemctl mask systemd-timesyncd.service 2>/dev/null || true
systemctl disable sshd.service 2>/dev/null || true
systemctl mask sshd.service 2>/dev/null || true

# git-credential-manager is not in Fedora/Terra/Fusion; isolated COPR.

install_priority mise

# bun-bin, deno (Terra rust-deno Name first), Zed stable (not nightly), mpv
# from Terra stable path via Name mpv, yt-dlp-git + ejs helper, then ffmpeg.
install_priority bun-bin
install_any rust-deno deno
install_priority zed
install_priority mpv yt-dlp-git python-yt-dlp-ejs
swap_ffmpeg_priority
install_priority steam
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
# Remove Flathub Firefox if the base image seeded it; we ship the RPM.
if command -v flatpak >/dev/null 2>&1; then
  flatpak uninstall --system -y org.mozilla.firefox || true
fi
# zen-browser: ladder RPMs first, else official release tarball (host-fetched).
install_any zen-browser || install_zen

# Brave official repo file written enabled=0; install with --enablerepo so
# the file stays default-off. helium-browser-bin is the Terra Name.
cat >/etc/yum.repos.d/brave-browser.repo <<'EOF'
[brave-browser]
name=Brave Browser
baseurl=https://brave-browser-rpm-release.s3.brave.com/$basearch
enabled=0
gpgcheck=1
gpgkey=https://brave-browser-rpm-release.s3.brave.com/brave-core.asc
EOF
dnf5 -y install --enablerepo=brave-browser brave-origin
install_any helium-browser-bin helium-browser

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
  gstreamer1-plugin-libav gstreamer1-plugin-openh264 gstreamer1-vaapi \
  mozilla-openh264 dav1d aom svt-av1 lame opus ffmpegthumbnailer \
  intel-media-driver libva-intel-driver gstreamer1-plugins-ugly x264 \
  totem-video-thumbnailer kdegraphics-thumbnailers icoextract-thumbnailer
install_any python3-icoextract

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

# KDE Wallet: kf6-kwallet ships the wallet daemon (kwalletd6) and ksecretd,
# the Secret Service provider (org.freedesktop.secrets) that git-credential-
# libsecret and the portal talk to. pam-kwallet auto-unlocks the default
# wallet (kdewallet, blowfish, password = user password) with the login
# password. The PAM lines are added at first boot by the ryven-keyring-pam
# oneshot; the plasma-kwallet-pam user unit is enabled by the ryven-user-units
# generator (compose has no user session, so `systemctl --user enable` cannot
# run here).
install_priority kf6-kwallet
install_priority pam-kwallet
systemctl enable ryven-keyring-pam.service
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
  if ! find "/usr/lib/modules/${KVER}/extra/openrazer" -name '*.ko*' -print -quit 2>/dev/null | grep -q .; then
    # Build via the patched scriptlet (same path as the %post): it carries
    # LLVM=1/KCFLAGS into akmodsbuild (env reset by the akmods client's
    # runuser -c call would otherwise leave gcc/ld.bfd against the
    # kernel's clang-LTO CFLAGS).
    # The akmod installs its modules (razeraccessory/razerkbd/razerkraken,
    # plus razermouse on some builds) under extra/openrazer/, NOT as
    # openrazer.ko - the check below looks at that directory.
    orzsrpm=$(ls /usr/src/akmods/openrazer-kmod-*.src.rpm 2>/dev/null | LC_ALL=C sort -V | tail -n1)
    [[ -n ${orzsrpm} ]] || die 'openrazer akmod SRPM not found under /usr/src/akmods'
    /usr/sbin/akmods-ostree-post openrazer "${orzsrpm}"
  fi
  find "/usr/lib/modules/${KVER}/extra/openrazer" -name '*.ko*' -print -quit 2>/dev/null | grep -q . || {
    echo '--- akmods log (last 40 lines) ---' >&2
    tail -n 40 /var/log/akmod/*.log /var/cache/akmods/*/*.failed.log 2>/dev/null || true
    die "akmods produced no openrazer kmod (extra/openrazer) for ${KVER}"
  }
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
  if grep -q '^IMAGE_ID=' /usr/lib/os-release; then
    sed -i 's/^IMAGE_ID=.*/IMAGE_ID="ryven"/' /usr/lib/os-release
  else
    # Start on a fresh line even if the file lacks a trailing newline.
    [[ -z $(tail -c1 /usr/lib/os-release) ]] || printf '\n' >>/usr/lib/os-release
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

# OpenRazer userspace + plugdev for udev. polychromatic: Terra/Fedora first,
# else OpenRazer hardware repo (disabled after install).
install_priority openrazer-daemon python3-openrazer
getent group plugdev >/dev/null || groupadd -r plugdev
if ! dnf5 -y install polychromatic; then
  vendor_repo_install '*razer*.repo' https://download.opensuse.org/repositories/hardware:/razer/Fedora_44/hardware:razer.repo polychromatic
fi

# MangoHud / obs-vkcapture 64-bit always. 32-bit only if a NEVRA exists so
# we do not fail the compose on arches/repos that omit i686. repoquery is
# used for the probe because `dnf5 list` exits 0 even with zero matches.
install_priority mangohud obs-vkcapture
if dnf5 repoquery --available "${TERRA_REPOS[@]/#/--enablerepo=}" "${FUSION_REPOS[@]/#/--enablerepo=}" --queryformat '%{name}.%{arch}\n' mangohud.i686 2>/dev/null | grep -q '^mangohud\.i686$'; then
  install_priority mangohud.i686
fi
if dnf5 repoquery --available "${TERRA_REPOS[@]/#/--enablerepo=}" "${FUSION_REPOS[@]/#/--enablerepo=}" --queryformat '%{name}.%{arch}\n' obs-vkcapture.i686 2>/dev/null | grep -q '^obs-vkcapture\.i686$'; then
  install_priority obs-vkcapture.i686
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

# Flatpaks must persist on host /var, not in the ostree /usr. First-boot
# oneshot installs the four allowed apps (Flatseal, Warehouse, Gear Lever,
# Bazaar) from Flathub then stamps /var/lib/ryven so it does not re-run.
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
[[ -f "${stamp}" ]] && exit 0
flatpak remote-add --if-not-exists --system flathub \
  https://dl.flathub.org/repo/flathub.flatpakrepo
mapfile -t apps < <(tr -d '\r' </usr/share/ryven/flatpaks | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d')
((${#apps[@]})) || exit 0
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
install_priority opencode-cli rpcs3 extest vicinae espanso-wayland
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

# Build-time invariants. No GPU, systemd is not PID 1: we only check files,
# rpmdb, and is-enabled symlinks. Any FAIL sets fail=1; die at the end so
# the layer does not publish a half-configured image.
smoke 'firefox rpm' rpm -q firefox
smoke 'nvidia kargs' test -f /usr/lib/bootc/kargs.d/00-nvidia.toml
smoke 'zswap kargs' test -f /usr/lib/bootc/kargs.d/10-zswap.toml
smoke 'nvidia kmod present' bash -c 'find /usr/lib/modules -name "nvidia*.ko*" -print -quit | grep -q .'
smoke 'nvidia-settings' rpm -q nvidia-settings
smoke 'nvidia-smi' command -v nvidia-smi
smoke 'ffmpeg rpm' rpm -q ffmpeg
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
smoke 'plasmalogin enabled' unit_enabled plasmalogin.service
smoke 'kernel singleton' bash -c '[[ $(ls /usr/lib/modules | wc -l) == 1 ]]'
smoke 'zen binary' test -x /opt/zen/zen/zen
smoke 'zen on PATH' command -v zen-browser
smoke 'zen desktop entry' test -f /usr/share/applications/zen.desktop
smoke_done
