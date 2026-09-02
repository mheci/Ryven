#!/bin/bash
# Ryven image compose. Invoked once from the Containerfile RUN as PID 1 of
# that layer. There is no real systemd here: `systemctl enable|disable|mask`
# only writes/removes unit wants and mask symlinks under /etc/systemd.
# `systemctl start` would be a no-op or fail; never start units in this script.
#
# Base image is ghcr.io/ublue-os/kinoite-main (Fedora 44 KDE). Overlay tree
# from /ctx/system_files is copied first so kargs, udev, environment.d, Plasma
# look-and-feel, and justfiles exist before RPM work that might assume them.
#
# Package source order is a standing product rule, applied per NEVRA Name
# (never one mixed-repo dnf transaction that can fail the whole set):
#   1. Official vendor/dev repos already on disk (Brave, mise, OpenRazer, …)
#   2. Terra f44: terra, terra-extras, terra-multimedia, terra-mesa
#   3. RPM Fusion free + nonfree including their -updates
#   4. Official Fedora (dnf default, no extra --enablerepo)
# COPR is last-resort only (zen-browser, gpu-screen-recorder) and the COPR
# repo file is disabled again after the install.
#
# terra-release-nvidia is never installed. NVIDIA kernel modules come from
# ublue akmods-nvidia-open:ogc-44 (prebuilt kmod-nvidia, not akmod-%post).
# CUDA packages are excluded. Third-party .repo files stay on the image but
# must be enabled=0 at rest; compose re-enables them with --enablerepo.
# Never `dnf swap mesa-*-freeworld --allowerasing`. Never kernel versionlock.

set -ouex pipefail

# Fedora major used in Fusion/Terra URL paths. Bump Fusion, Terra, and the
# Containerfile FROM together when leaving 44.
readonly FEDORA_RELEASE=44
# Comma list for dnf5 --enablerepo. terra-extras is the extras subrepo from
# terra-release-extras (%package extras), not a separate product.
readonly TERRA_REPOS='terra,terra-extras,terra-multimedia,terra-mesa'
readonly FUSION_REPOS='rpmfusion-free,rpmfusion-free-updates,rpmfusion-nonfree,rpmfusion-nonfree-updates'
# Open Gaming Collective kernel RPM OCI (skopeo dir copy). Tag tracks fc44.
readonly OGC_IMAGE='ghcr.io/opengamingcollective/kernel-packages-fedora:latest-fc44'
# CachyOS Proton Steam Linux Runtime build. Asset names on GitHub omit .tar.xz
# from the .sha512sum filename; keep both strings in lockstep when bumping.
readonly PROTON_CACHYOS_VER='11.0-20260703-slr'
# rpm-ostree kernel-install plugins assume a booted ostree. During kernel
# RPM replace they try to run and fail the transaction; we stub then restore.
readonly KERNEL_INSTALL_STUBS=(05-rpmostree.install 50-dracut.install)

die() {
  echo "$*" >&2
  exit 1
}

# True if RPM Name (or NEVRA) is already in the rpmdb. Used to skip installs
# and to decide ffmpeg-free vs ffmpeg before swap.
have_rpm() {
  rpm -q "$1" >/dev/null 2>&1
}

# Leave yum/dnf repo files on disk (needed for later --enablerepo) but force
# enabled=0 so a booted host does not pull from Terra/Fusion/vendor by default.
# Globs are expanded by the caller or via nullglob inside; missing files skip.
disable_yum_repos() {
  local repo
  shopt -s nullglob
  for repo in "$@"; do
    [[ -f ${repo} ]] || continue
    sed -i 's/^enabled=1/enabled=0/' "${repo}"
  done
}

# install_priority [--official-repo=ID] PKG...
# Resolve each Name independently so a Terra-only Name and a Fusion-only Name
# in one call cannot fail the whole dnf5 transaction (dnf5 is all-or-nothing).
# Optional --official-repo may be repeated (Brave, mise). Order per pkg:
# already installed → official repo(s) → Terra set → Fusion set → Fedora.
# Returns 1 if any Name has no NEVRA in that ladder (caller may fallback).
install_priority() {
  local official=()
  local pkg
  while [[ ${1-} == --official-repo=* ]]; do
    official+=(--enablerepo="${1#--official-repo=}")
    shift
  done
  for pkg in "$@"; do
    if have_rpm "${pkg}"; then
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

# Try Names in order until one installs. Used for nightly vs stable aliases
# (ghostty-tip vs ghostty) and Terra vs Fedora names (helium-browser-bin).
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

# Fedora ships ffmpeg-free. We want full ffmpeg. Prefer Terra swap (same
# priority ladder as packages); Fusion swap is next; then a fresh install.
# --allowerasing is required because the two packages conflict on files.
swap_ffmpeg_priority() {
  if have_rpm ffmpeg; then
    return 0
  fi
  if have_rpm ffmpeg-free; then
    if dnf5 -y swap --enablerepo="${TERRA_REPOS}" --allowerasing ffmpeg-free ffmpeg; then
      return 0
    fi
    if dnf5 -y swap --enablerepo="${FUSION_REPOS}" --allowerasing ffmpeg-free ffmpeg; then
      return 0
    fi
  fi
  install_priority ffmpeg
}

# Enable a COPR, install listed packages, immediately disable the COPR repo
# file. The packages stay in rpmdb; later dnf on the host will not use COPR
# unless an admin re-enables it. Fail hard if enable or install fails.
copr_install_isolated() {
  local copr=$1
  shift
  dnf5 -y copr enable "${copr}"
  dnf5 -y install "$@"
  dnf5 -y copr disable "${copr}"
}

# Add a vendor .repo from URL (overwrite if compose is re-run), install the
# remaining argv packages, then disable matching repo files so they are not
# default-on. glob is a basename glob under /etc/yum.repos.d (unquoted so
# the shell can expand *mise*.repo / *razer*.repo).
vendor_repo_install() {
  local glob=$1
  local url=$2
  shift 2
  dnf5 -y config-manager addrepo --overwrite --from-repofile="${url}"
  dnf5 -y install "$@"
  disable_yum_repos /etc/yum.repos.d/${glob}
}

# Replace rpm-ostree/dracut kernel-install plugins with `exit 0` so dnf can
# replace kernel-core in an unbooted container. Restored after depmod.
stub_kernel_install_hooks() {
  local f
  [[ -d /usr/lib/kernel/install.d ]] || return 0
  pushd /usr/lib/kernel/install.d >/dev/null
  for f in "${KERNEL_INSTALL_STUBS[@]}"; do
    if [[ -e ${f} ]]; then
      mv "${f}" "${f}.bak"
      printf '%s\n' '#!/bin/sh' 'exit 0' >"${f}"
      chmod +x "${f}"
    fi
  done
  popd >/dev/null
}

restore_kernel_install_hooks() {
  local f
  [[ -d /usr/lib/kernel/install.d ]] || return 0
  pushd /usr/lib/kernel/install.d >/dev/null
  for f in "${KERNEL_INSTALL_STUBS[@]}"; do
    if [[ -e ${f}.bak ]]; then
      mv -f "${f}.bak" "${f}"
    fi
  done
  popd >/dev/null
}

# Install prebuilt kmod-* and *-kmod-common RPMs with rpm --nodeps (dep chain
# is the OGC kernel we just installed, not Fedora's). Skip akmod-* : those
# expect a %post compile as root on a booted system and would leave no .ko.
# Empty match is a warning, not a hard fail (optional extra kmods).
install_kmod_bundle() {
  local -a rpms=()
  local f
  for f in "$@"; do
    [[ -f ${f} ]] || continue
    [[ ${f##*/} == akmod-* ]] && continue
    rpms+=("${f}")
  done
  if ((${#rpms[@]} == 0)); then
    echo "No matching prebuilt kmod RPMs for: $*" >&2
    return 0
  fi
  rpm --install --nodeps "${rpms[@]}"
}

# Copy the OGC kernel OCI to a dir transport, then extract only kernel* RPM
# layers. OCI layers may be tar or raw RPM blobs; title annotation is the
# filename. Exclude kernel-headers / unrelated packages via the title regex.
extract_ogc_kernel() {
  local dest=$1
  local manifest=/tmp/ogc-oci/manifest.json
  local layer title digest blob
  mkdir -p "${dest}" /tmp/ogc-oci
  skopeo copy --retry-times 3 "docker://${OGC_IMAGE}" dir:/tmp/ogc-oci
  [[ -f ${manifest} ]] || {
    ls -la /tmp/ogc-oci >&2
    die 'OGC kernel OCI manifest missing'
  }
  while read -r layer; do
    title=$(jq -r '.annotations["org.opencontainers.image.title"] // empty' <<<"${layer}")
    digest=$(jq -r '.digest' <<<"${layer}")
    [[ -n ${title} && -n ${digest} ]] || continue
    if ! grep -qE '^(kernel-[0-9]|kernel-core-|kernel-devel-|kernel-devel-matched-|kernel-modules-|kernel-modules-core-|kernel-modules-extra-|kernel-tools)' <<<"${title}"; then
      continue
    fi
    blob=/tmp/ogc-oci/${digest#sha256:}
    [[ -f ${blob} ]] || die "OGC blob missing for ${title} (${digest})"
    echo "OGC kernel RPM: ${title}"
    if tar tf "${blob}" >/dev/null 2>&1; then
      tar xf "${blob}" -C "${dest}"
    else
      cp -a "${blob}" "${dest}/${title}"
    fi
  done < <(jq -c '.layers[]' "${manifest}")
}

# systemctl is-enabled prints enabled|disabled|masked|static|…. Compare to
# the string enabled. Missing units are not enabled.
unit_enabled() {
  [[ $(systemctl is-enabled "$1" 2>/dev/null || true) == enabled ]]
}

# Overlay /ctx/system_files onto the image root. Paths here are the source of
# truth for kargs.d, environment.d, udev, sysctl, Plasma, justfiles, pixmaps.
cp -avf /ctx/system_files/. /

# RPM Fusion release RPMs drop /etc/yum.repos.d/rpmfusion-*.repo. Version in
# the URL must match FEDORA_RELEASE. Files are disabled after Terra bootstrap.
dnf5 -y install \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_RELEASE}.noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_RELEASE}.noarch.rpm"

# Terra bootstrap: --nogpgcheck + --repofrompath only until terra-release
# lands (it ships the FyraLabs signing keys and terra.repo). Then install
# extras/mesa/multimedia subpackages from the now-signed terra repo.
# Do not install terra-release-nvidia.
dnf5 -y install --nogpgcheck \
  --repofrompath "terra,https://repos.fyralabs.com/terra${FEDORA_RELEASE}" \
  terra-release
dnf5 -y install --enablerepo=terra \
  terra-release-extras \
  terra-release-mesa \
  terra-release-multimedia

# Default-off: Fusion and all Terra repo files (terra, extras, mesa, multimedia).
disable_yum_repos /etc/yum.repos.d/rpmfusion*.repo /etc/yum.repos.d/*terra*.repo

# OGC kernel replace + ublue ogc-44 kmods (xone, xpadneo, openrazer, ryzen_smu,
# zenergy, NVIDIA open). Stub kernel-install first so rpm -e / dnf install of
# kernel-core does not invoke rpm-ostree plugins in this unbooted tree.
stub_kernel_install_hooks
dnf5 -y install jq skopeo
extract_ogc_kernel /tmp/kernel-rpms
compgen -G '/tmp/kernel-rpms/kernel-core-*.rpm' >/dev/null ||
  die 'OGC kernel-core RPM missing under /tmp/kernel-rpms'

# Erase Fedora/ublue kernel Names (nodeps: we immediately install OGC). Wipe
# /usr/lib/modules so leftover .ko from the old kver cannot confuse depmod.
local_pkg=
for local_pkg in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-tools kernel-tools-libs; do
  if have_rpm "${local_pkg}"; then
    rpm --erase "${local_pkg}" --nodeps
  fi
done
rm -rf /usr/lib/modules/*

# Globs must expand to real RPMs; dnf5 install of a literal glob would fail.
dnf5 -y install \
  /tmp/kernel-rpms/kernel-[0-9]*.rpm \
  /tmp/kernel-rpms/kernel-core-*.rpm \
  /tmp/kernel-rpms/kernel-modules-*.rpm \
  /tmp/kernel-rpms/kernel-devel-*.rpm

# Single kver string for depmod and nvidia .ko path checks. sort -V + tail if
# more than one kernel-core ever landed (should be one after the erase).
KVER=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n1)

# ublue-os-akmods COPR is on the base image disabled. Enable only long enough
# to install addons if the COPY --from=akmods tree did not already provide them.
if [[ -f /etc/yum.repos.d/_copr_ublue-os-akmods.repo ]]; then
  sed -i 's@enabled=0@enabled=1@g' /etc/yum.repos.d/_copr_ublue-os-akmods.repo
fi
if compgen -G '/tmp/akmods-rpms/ublue-os/ublue-os-akmods-addons*.rpm' >/dev/null; then
  dnf5 -y install /tmp/akmods-rpms/ublue-os/ublue-os-akmods-addons*.rpm
elif compgen -G '/tmp/akmods-rpms/ublue-os/ublue-os-akmods*.rpm' >/dev/null; then
  dnf5 -y install /tmp/akmods-rpms/ublue-os/ublue-os-akmods*.rpm
fi

# Gamepad + Razer hid kmods from the ublue akmods COPY. Multiple glob paths
# because ublue has shuffled kmods/ vs common/ layouts across tags.
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

# Extra out-of-tree modules (ryzen_smu, zenergy) from the akmods-extra COPY.
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

# nvidia-vars is written by ublue's akmods-nvidia-open:ogc-44 image; absence
# means the Containerfile COPY --from= that stage was dropped or empty.
AKMODNV_PATH=/tmp/akmods-nvidia-rpms
[[ -f ${AKMODNV_PATH}/kmods/nvidia-vars ]] ||
  die "akmods-nvidia-open:ogc-44 missing ${AKMODNV_PATH}/kmods/nvidia-vars"

# ublue ships nvidia-install.sh; it expects IMAGE_NAME and AKMODNV_PATH in
# the environment. MULTILIB=1 pulls i686 NVIDIA userspace for Steam/Proton.
INSTALL_SH=
if [[ -x ${AKMODNV_PATH}/ublue-os/nvidia-install.sh || -f ${AKMODNV_PATH}/ublue-os/nvidia-install.sh ]]; then
  INSTALL_SH=${AKMODNV_PATH}/ublue-os/nvidia-install.sh
else
  INSTALL_SH=$(find /tmp/akmods-nvidia-rpms -name nvidia-install.sh -type f -print -quit)
fi
[[ -n ${INSTALL_SH} ]] || die 'nvidia-install.sh missing from akmods-nvidia-open:ogc-44'

# IMAGE_NAME=kinoite selects the kinoite branch (supergfxctl / Plasma bits)
# inside nvidia-install.sh rather than silverblue/gnome.
IMAGE_NAME=kinoite AKMODNV_PATH="${AKMODNV_PATH}" MULTILIB=1 bash "${INSTALL_SH}"

# Nouveau Vulkan ICD would race NVIDIA. Unversioned libnvidia-ml.so is what
# several tools dlopen; the SONAME is libnvidia-ml.so.1.
rm -f /usr/share/vulkan/icd.d/nouveau_icd.*.json
if [[ -e /usr/lib64/libnvidia-ml.so.1 ]]; then
  ln -sf libnvidia-ml.so.1 /usr/lib64/libnvidia-ml.so
fi
depmod -a "${KVER}"
restore_kernel_install_hooks

# bootc kargs.d is applied on next bootc/rpm-ostree deploy. Nouveau blocked;
# nvidia drm modeset + fbdev; simpledrm initcall blacklisted so NVIDIA owns
# the console; PreserveVideoMemoryAllocations + /var/tmp for suspend; ReBAR,
# PCIe gen3, PAT, stream memops, no D3 dynamic PM (gaming), GPU GSP firmware,
# PerfLevelSrc=0x2222 (prefer max clocks). Do not set LIBVA_DRIVER_NAME here.
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

# Fusion VA-API NVIDIA driver for both ISAs (Steam 32-bit). Exclude CUDA.
# vulkan-loader both ISAs from the priority ladder. nvidia-settings from
# Fusion only if the ublue nvidia-install.sh did not already provide it.
dnf5 -y install \
  --enablerepo="${FUSION_REPOS}" \
  --exclude='cuda*' \
  --exclude='*nvidia*cuda*' \
  libva-nvidia-driver.x86_64 \
  libva-nvidia-driver.i686
install_priority vulkan-loader.x86_64 vulkan-loader.i686 vulkan-tools
if ! have_rpm nvidia-settings; then
  dnf5 -y install --enablerepo="${FUSION_REPOS}" --exclude='cuda*' nvidia-settings
fi

# Base OS: just (ujust), Secure Boot tooling, LUKS/TPM unlock, chrony (not
# timesyncd), podman (not docker), firewalld, git+gh, sudo-rs, Flatpak binary
# for first-boot host installs, Plasma Login Manager (not SDDM), greenboot,
# Firefox RPM (not the Flathub app).
dnf5 -y install \
  just mokutil shim efibootmgr \
  cryptsetup clevis clevis-luks clevis-dracut tpm2-tools \
  chrony podman podman-compose firewalld \
  git gh git-credential-libsecret \
  sudo-rs flatpak \
  plasma-login-manager kcm-plasmalogin \
  greenboot greenboot-default-health-checks \
  firefox

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
copr_install_isolated vdanielmo/git-credential-manager git-credential-manager

# mise (jdx) is not in Fedora 44. Try Fedora first in case that changes, then
# the official RPM repo; disable the repo file after install.
if ! dnf5 -y install mise; then
  vendor_repo_install '*mise*.repo' https://mise.jdx.dev/rpm/mise.repo mise
fi

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
# zen-browser: Terra/Fedora first; sneexy COPR only if no NEVRA.
if ! install_any zen-browser; then
  copr_install_isolated sneexy/zen-browser zen-browser
fi

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
if ! dnf5 -y distro-sync --enablerepo="${TERRA_REPOS}" \
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
dnf5 -y install --enablerepo=rpmfusion-free --enablerepo="${FUSION_REPOS}" rpmfusion-free-release-tainted
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

# Plasma Login Manager is the display manager. Mask SDDM if the unit exists
# so a later package cannot re-enable it as default.
systemctl enable --force plasmalogin.service
if [[ -f /usr/lib/systemd/system/sddm.service ]] || systemctl list-unit-files sddm.service >/dev/null 2>&1; then
  systemctl disable sddm.service
  systemctl mask sddm.service
fi

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
  ln -sf scopebuddy /usr/bin/scb
fi

# beesd: online btrfs dedup. Config UUID is host-specific, so a oneshot
# writes /etc/bees/${UUID}.conf and a generator enables beesd@UUID only when
# /var/home or / is btrfs. Harmless no-op on ext4/xfs test VMs.
install_priority bees
mkdir -p /usr/lib/systemd/system-generators /usr/libexec /etc/bees /usr/lib/systemd/system
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

# OpenRazer userspace + plugdev for udev. polychromatic: Terra/Fedora first,
# else OpenRazer hardware repo (disabled after install).
install_priority openrazer-daemon python3-openrazer
getent group plugdev >/dev/null || groupadd -r plugdev
if ! dnf5 -y install polychromatic; then
  vendor_repo_install '*razer*.repo' https://openrazer.github.io/hardware:razer.repo polychromatic
fi

# MangoHud / obs-vkcapture 64-bit always. 32-bit only if a NEVRA exists so
# we do not fail the compose on arches/repos that omit i686.
install_priority mangohud obs-vkcapture
if dnf5 list --available --enablerepo="${TERRA_REPOS}" --enablerepo="${FUSION_REPOS}" mangohud.i686 >/dev/null 2>&1; then
  install_priority mangohud.i686
fi
if dnf5 list --available --enablerepo="${TERRA_REPOS}" --enablerepo="${FUSION_REPOS}" obs-vkcapture.i686 >/dev/null 2>&1; then
  install_priority obs-vkcapture.i686
fi
install_any goverlay

# I/O scheduler udev: kyber on NVMe, bfq on rotational, mq-deadline on SATA
# SSD. ATTR match requires the scheduler to be in the available list.
# Remove the old 60-ryven-kyber.rules name if a previous layer left it.
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
if ! install_priority gpu-screen-recorder; then
  copr_install_isolated brycensranch/gpu-screen-recorder-git gpu-screen-recorder
fi
install_priority bibata-cursor-theme klassy tela-icon-theme
[[ -f /usr/lib/systemd/system/bpftune.service ]] ||
   die 'bpftune-gaming missing bpftune.service'
systemctl enable bpftune.service ananicy-cpp.service

# Pinned CachyOS Proton SLR tarball. sha512sum file lists the tar name without
# requiring us to rewrite it. Fail if compatibilitytool.vdf is missing after
# extract (Steam will not list the tool). Not curl|sh.
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

# Build-time invariants. No GPU, systemd is not PID 1: we only check files,
# rpmdb, and is-enabled symlinks. Any FAIL sets fail=1; die at the end so
# the layer does not publish a half-configured image.
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

check 'firefox rpm' rpm -q firefox
check 'git on PATH' command -v git
check 'gh on PATH' command -v gh
check 'mise on PATH' command -v mise
check 'nvidia kargs' test -f /usr/lib/bootc/kargs.d/00-nvidia.toml
check 'nvidia modprobe' test -f /usr/lib/modprobe.d/nvidia-gaming.conf
check 'shader cache env' test -f /usr/lib/environment.d/50-ryven-shader-cache.conf
check 'zswap kargs' test -f /usr/lib/bootc/kargs.d/10-zswap.toml
check 'amd zen kargs' test -f /usr/lib/bootc/kargs.d/20-amd-zen.toml
check 'ujust wrapper' test -x /usr/bin/ujust
check 'ryven justfile' test -f /usr/share/ryven/justfile
check 'chronyd enabled' unit_enabled chronyd.service
check 'sshd not enabled' bash -c 's=$(systemctl is-enabled sshd.service 2>/dev/null || true); [[ $s != enabled ]]'
check 'firewalld enabled' unit_enabled firewalld.service
check 'nvidia kmod present' bash -c 'find /usr/lib/modules -name "nvidia*.ko*" -print -quit | grep -q .'
check 'ffmpeg rpm' rpm -q ffmpeg
check 'libva-nvidia-driver' rpm -q libva-nvidia-driver
check 'zram generator disabled' bash -c '! systemctl is-enabled systemd-zram-setup@zram0.service 2>/dev/null | grep -qx enabled'
check 'no firefox flatpak' bash -c '! command -v flatpak >/dev/null || ! flatpak info --system org.mozilla.firefox >/dev/null 2>&1'
check 'ryven look-and-feel' test -f /usr/share/plasma/look-and-feel/org.ryven.desktop/metadata.json
check 'ryven color scheme' test -f /usr/share/color-schemes/Ryven.colors
check 'ryven wallpaper' test -f /usr/share/wallpapers/Ryven/contents/images/3840x2160.png
check 'ryven kdeglobals' grep -q 'LookAndFeelPackage=org.ryven.desktop' /etc/xdg/kdeglobals
check 'inter font default' grep -q 'font=Inter,' /etc/xdg/kdeglobals
check 'darkly widgetStyle' grep -q 'widgetStyle=Darkly' /etc/xdg/kdeglobals
check 'plasmalogin enabled' unit_enabled plasmalogin.service
check 'sddm not enabled' bash -c 's=$(systemctl is-enabled sddm.service 2>/dev/null || true); [[ $s != enabled ]]'
check 'io scheduler udev' test -f /usr/lib/udev/rules.d/60-ryven-io-scheduler.rules
check 'ntsync udev' test -f /usr/lib/udev/rules.d/40-ryven-ntsync.rules
check 'ntsync modules-load' test -f /usr/lib/modules-load.d/ntsync.conf
check 'desktop sysctl' test -f /usr/lib/sysctl.d/70-ryven-desktop.conf
check 'scx default lavd' grep -q 'SCX_SCHEDULER=scx_lavd' /etc/default/scx
check 'scx_loader.toml' grep -q 'default_sched = "scx_lavd"' /etc/scx_loader.toml
check 'scx_loader enabled' unit_enabled scx_loader.service
check 'ananicy-cpp enabled' unit_enabled ananicy-cpp.service
check 'bpftune enabled' unit_enabled bpftune.service
check 'no cardwire' bash -c '! rpm -q cardwire >/dev/null 2>&1'
check 'proton wayland' grep -q 'PROTON_ENABLE_WAYLAND=1' /usr/lib/environment.d/60-ryven-proton.conf
check 'no WINEFSYNC' bash -c '! grep -q WINEFSYNC /usr/lib/environment.d/60-ryven-proton.conf'
check 'flatpak first-boot unit' test -f /usr/lib/systemd/system/ryven-flatpak-setup.service
check 'bees generator' test -x /usr/lib/systemd/system-generators/ryven-bees-generator
check 'greenboot rpm' rpm -q greenboot
check 'greenboot redboot-auto-reboot' bash -c '
  if [[ -f /usr/lib/systemd/system/redboot-auto-reboot.service ]]; then
    [[ $(systemctl is-enabled redboot-auto-reboot.service) == enabled ]]
  else
    true
  fi
'
check 'proton-cachyos vdf' bash -c 'find /usr/share/steam/compatibilitytools.d -name compatibilitytool.vdf | grep -q .'
check 'helium-browser-bin' rpm -q helium-browser-bin
check 'gpu-screen-recorder' rpm -q gpu-screen-recorder
check 'polychromatic' rpm -q polychromatic
check 'docker group empty or absent' bash -c '
  if getent group docker >/dev/null; then
    members=$(getent group docker | cut -d: -f4)
    [[ -z ${members} ]]
  else
    true
  fi
'
check 'terra-extras repo file' test -f /etc/yum.repos.d/terra-extras.repo

if [[ ${fail} -ne 0 ]]; then
  die 'Image invariant checks failed.'
fi
echo 'Image invariant checks passed.'
