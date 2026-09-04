#!/bin/bash
# compose.sh — single shared core for all Ryven images. Sourced, not executed.
# Callers set `set -euo pipefail` first, then `source /ctx/compose.sh`.
#
# Standing rules (product policy, do not relax without a user decision):
#   Source ladder: official dev repo > Terra(+subs) > RPMFusion > Fedora >
#     cargo source builds > Flatpak (last resort, first-boot only).
#   Everything floats to latest. No version pins, no digest pins, no SHAs.
#   Third-party repos are disabled at rest; enabled per-transaction only (RC-1).
#   No terra-release-nvidia exclusion needed: NVIDIA comes FROM terra-nvidia.
#   No mesa-freeworld swap. No CUDA toolkit (driver CUDA runtime libs ship).
#   No docker. zswap on / zram off. No LIBVA_DRIVER_NAME=nvidia.
#   Quiet by default: section headers + one line per package. Failures are
#   loud (tailed logs) and fail-closed.

# Base Fedora release, detected from the running base image (`:latest` floats).
FEDORA_RELEASE="$(source /etc/os-release && echo "${VERSION_ID}")"
[[ "${FEDORA_RELEASE}" =~ ^[0-9]+$ ]] || { echo "COMPOSE-FAIL: cannot detect Fedora release" >&2; exit 1; }

readonly -a TERRA_REPOS=(terra terra-extras terra-multimedia terra-mesa)
readonly -a TERRA_NVIDIA_REPOS=(terra-nvidia)
readonly -a FUSION_REPOS=(rpmfusion-free rpmfusion-free-updates rpmfusion-nonfree rpmfusion-nonfree-updates)
readonly CACHYOS_COPR='bieszczaders/kernel-cachyos-lto'
readonly -a KERNEL_INSTALL_STUBS=(05-rpmostree.install 50-dracut.install)

say() { echo "=== $*"; }
die() { echo "COMPOSE-FAIL: $*" >&2; exit 1; }
have_rpm() { rpm -q "$1" >/dev/null 2>&1; }
unit_enabled() { [[ "$(systemctl is-enabled "$1" 2>/dev/null || true)" == "enabled" ]]; }
require_src() { [[ -f "$1" ]] || die "overlay source missing: $1"; }

# Run quietly, keep the log for failure tails.
_q() { "$@" >/tmp/compose-last.log 2>&1; }

# retry N TAG CMD... — every remote bootstrap goes through this.
retry() {
  local n=$1 tag=$2
  shift 2
  local i rc=0
  for i in $(seq 1 "${n}"); do
    if _q "$@"; then return 0; fi
    rc=$?
    if [[ "${i}" == "${n}" ]]; then
      echo "--- ${tag} failed after ${n} attempts (rc=${rc}), tail: ---" >&2
      tail -n 25 /tmp/compose-last.log >&2 || true
      return "${rc}"
    fi
    echo "${tag}: attempt ${i}/${n} failed (rc=${rc}), retrying in 30s" >&2
    dnf5 clean metadata >/dev/null 2>&1 || true
    sleep 30
  done
}

# RC-1: lock down every third-party repo inherited from the base image
# (ublue-os:akmods COPR, fedora-multimedia, vendor files...). Only the Fedora
# family stays enabled. Everything else is enabled per-transaction and returns
# to disabled at rest.
lockdown_base_repos() {
  say 'repo lockdown (RC-1): Fedora-family only'
  local f
  shopt -s nullglob
  for f in /etc/yum.repos.d/*.repo; do
    awk '
      /^\[.+\]/ { sec = substr($0, 2, length($0) - 2) }
      /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*1/ {
        if (sec !~ /^(fedora|updates|updates-archive|fedora-cisco-openh264)$/) { sub(/=.*/, "=0") }
      }
      { print }
    ' "${f}" >"${f}.tmp" && mv "${f}.tmp" "${f}"
  done
  shopt -u nullglob
}

# Force enabled=0 on repo files (kept on disk for later --enablerepo).
disable_yum_repos() {
  local repo was_off=0
  shopt -q nullglob || was_off=1
  shopt -s nullglob
  for repo in "$@"; do
    [[ -f ${repo} ]] || continue
    sed -i -E 's/^[[:space:]]*enabled[[:space:]]*=[[:space:]]*1([[:space:]]|$)/enabled=0\1/' "${repo}"
  done
  if ((was_off)); then shopt -u nullglob; fi
  return 0
}

# install_priority [--official-repo=ID] PKG... — one Name per transaction so a
# Terra-only and a Fusion-only Name in one call cannot fail each other.
install_priority() {
  local official=() pkg
  while [[ ${1-} == --official-repo=* ]]; do
    official+=(--enablerepo="${1#--official-repo=}")
    shift
  done
  for pkg in "$@"; do
    if have_rpm "${pkg}"; then continue; fi
    if ((${#official[@]})) && _q dnf5 -y install "${official[@]}" "${pkg}"; then echo "pkg: ${pkg} (vendor)"; continue; fi
    if _q dnf5 -y install "${TERRA_REPOS[@]/#/--enablerepo=}" "${pkg}"; then echo "pkg: ${pkg} (terra)"; continue; fi
    if _q dnf5 -y install "${FUSION_REPOS[@]/#/--enablerepo=}" "${pkg}"; then echo "pkg: ${pkg} (fusion)"; continue; fi
    if _q dnf5 -y install "${pkg}"; then echo "pkg: ${pkg} (fedora)"; continue; fi
    echo "No NEVRA for ${pkg} in vendor/Terra/Fusion/Fedora" >&2
    tail -n 12 /tmp/compose-last.log >&2 || true
    return 1
  done
}

# Try Names in order until one installs (nightly vs stable aliases).
install_any() {
  local name
  for name in "$@"; do
    if install_priority "${name}"; then return 0; fi
  done
  echo "No provider for: $*" >&2
  return 1
}

# Full ffmpeg over ffmpeg-free, Terra first then Fusion.
swap_ffmpeg_priority() {
  if have_rpm ffmpeg; then return 0; fi
  if have_rpm ffmpeg-free; then
    if _q dnf5 -y swap "${TERRA_REPOS[@]/#/--enablerepo=}" --allowerasing ffmpeg-free ffmpeg; then return 0; fi
    if _q dnf5 -y swap "${FUSION_REPOS[@]/#/--enablerepo=}" --allowerasing ffmpeg-free ffmpeg; then return 0; fi
  fi
  install_priority ffmpeg
}

# Enable a COPR, install, immediately disable. Disabled again even on failure.
copr_install_isolated() {
  local copr=$1
  shift
  local rc=0
  dnf5 -y copr enable "${copr}" >/tmp/compose-last.log 2>&1 || return 1
  _q dnf5 -y install "$@" || rc=$?
  dnf5 -y copr disable "${copr}" >/dev/null 2>&1 || true
  return "${rc}"
}

# Vendor .repo from URL (overwrite), install argv, disable the file at rest.
vendor_repo_install() {
  local glob=$1 url=$2
  shift 2
  local rc=0 was_off=0
  local -a matches=()
  shopt -q nullglob || was_off=1
  shopt -s nullglob
  dnf5 -y config-manager addrepo --overwrite --from-repofile="${url}" >/tmp/compose-last.log 2>&1 || rc=$?
  if ((rc == 0)); then _q dnf5 -y install "$@" || rc=$?; fi
  matches=(/etc/yum.repos.d/"${glob}")
  if ((was_off)); then shopt -u nullglob; fi
  if ((${#matches[@]})); then disable_yum_repos "${matches[@]}"; fi
  return "${rc}"
}

# rpm-ostree/dracut kernel-install plugins assume a booted ostree; stub them
# for kernel replace in this unbooted tree, restore afterwards.
stub_kernel_install_hooks() {
  local f
  [[ -d /usr/lib/kernel/install.d ]] || return 0
  (
    cd /usr/lib/kernel/install.d || exit 1
    for f in "${KERNEL_INSTALL_STUBS[@]}"; do
      if [[ -e ${f} ]]; then
        mv "${f}" "${f}.bak"
        printf '%s\n' '#!/bin/sh' 'exit 0' >"${f}"
        chmod +x "${f}"
      fi
    done
  )
}

restore_kernel_install_hooks() {
  local f
  [[ -d /usr/lib/kernel/install.d ]] || return 0
  (
    cd /usr/lib/kernel/install.d || exit 1
    for f in "${KERNEL_INSTALL_STUBS[@]}"; do
      if [[ -e ${f}.bak ]]; then mv -f "${f}.bak" "${f}"; fi
    done
  )
}

# akmods 0.6.x: akmod %post runs akmods-ostree-post as root, but akmodsbuild
# refuses root. Apply the upstream privilege-drop pattern plus the clang/LTO
# toolchain env (LTO kernel needs CC=clang LD=ld.lld LLVM=1, plain-ELF KCFLAGS).
fix_akmods_ostree_post() {
  local ostree_post=/usr/sbin/akmods-ostree-post
  [[ -f ${ostree_post} ]] || return 0
  if grep -q 'runuser' "${ostree_post}"; then return 0; fi
  if ! sed -E -i '0,/^([[:space:]]*)akmodsbuild /s||\1chown akmods "${tmpdir}" "${tmpdir}results" \&\& unset TMPDIR \&\& CC=clang LD=ld.lld LLVM=1 KCFLAGS="-fno-lto -fno-split-lto-unit" MAKEFLAGS="-j$(nproc)" /usr/sbin/runuser -u akmods -- /usr/bin/akmodsbuild |' "${ostree_post}"; then
    die "failed to patch ${ostree_post}"
  fi
  grep -q '/usr/sbin/runuser' "${ostree_post}" || die "akmods-ostree-post patch did not apply"
  bash -n "${ostree_post}" || die "patched ${ostree_post} failed syntax check"
}

# CachyOS kernel set from COPR over the Fedora set. Base set is fatal;
# modules-extra and unmatched devel are best-effort.
_install_cachyos_once() {
  dnf5 -y copr enable "${CACHYOS_COPR}" >/dev/null 2>&1 || return 1
  dnf5 -y install kernel-cachyos-lto kernel-cachyos-lto-devel-matched >/tmp/compose-last.log 2>&1 || return 1
  dnf5 -y install kernel-cachyos-lto-modules-extra >/dev/null 2>&1 ||
    echo 'kernel-cachyos-lto-modules-extra unavailable; continuing' >&2
  dnf5 -y install kernel-cachyos-lto-devel >/dev/null 2>&1 ||
    echo 'kernel-cachyos-lto-devel unavailable; continuing' >&2
  return 0
}

install_cachyos_kernel() {
  retry 6 cachyos-kernel _install_cachyos_once || die 'CachyOS kernel install failed'
  dnf5 -y copr disable "${CACHYOS_COPR}" >/dev/null 2>&1 || true
}

# Build a kmod via the patched scriptlet (the akmods client cannot carry the
# LLVM/KCFLAGS env). $1 akmod name, $2 find pattern, $3 kver, $4 SRPM glob.
build_kmod() {
  mkdir -p /run/akmods
  chown root:akmods /run/akmods
  chmod 0770 /run/akmods
  if ! find "/usr/lib/modules/$3" -path "*$2" -print -quit 2>/dev/null | grep -q .; then
    local srpm
    srpm=$(ls /usr/src/akmods/$4 2>/dev/null | LC_ALL=C sort -V | tail -n1)
    [[ -n ${srpm} ]] || die "$1 akmod SRPM not found under /usr/src/akmods"
    /usr/sbin/akmods-ostree-post "$1" "${srpm}"
  fi
  if ! find "/usr/lib/modules/$3" -path "*$2" -print -quit 2>/dev/null | grep -q .; then
    echo '--- akmods log (last 40 lines) ---' >&2
    tail -n 40 /var/log/akmod/*.log /var/cache/akmods/*/*.failed.log 2>/dev/null || true
    die "akmods produced no $2 for $3"
  fi
}

# SELinux booleans for Proton/Wine JIT + out-of-tree module loads. Best-effort
# per boolean so one unavailable boolean cannot fail the compose.
apply_selinux_game_booleans() {
  local b
  for b in selinuxuser_execmod selinuxuser_execstack selinuxuser_execheap domain_kernel_load_modules; do
    if command -v semanage >/dev/null 2>&1 && semanage boolean -m --on "${b}" >/dev/null 2>&1; then
      continue
    fi
    setsebool -P "${b}" 1 2>/dev/null || echo "SELinux boolean ${b} unavailable" >&2
  done
}

# Overlay trees onto the image root + restore the atomic /usr/local symlink
# layout. Called at compose start AND re-asserted after the final upgrade
# (RC-3: later rpm transactions may clobber overlay-owned paths).
apply_overlay() {
  local d
  if [[ ! -d /usr/local ]]; then rm -rf /usr/local; fi
  for d in "$@"; do
    cp -af "/ctx/${d}/." /
  done
  if [[ -d /usr/local && ! -L /usr/local ]]; then
    if [[ -e /var/usrlocal || -L /var/usrlocal ]]; then
      cp -a /usr/local/. /var/usrlocal/
    else
      mv /usr/local /var/usrlocal
    fi
    rm -rf /usr/local
  fi
  if [[ ! -e /usr/local && ! -L /usr/local ]]; then ln -s /var/usrlocal /usr/local; fi
}

# Terra bootstrap: keys + main release, then subrepo releases (incl. nvidia).
_terra_once() {
  dnf5 -y install --nogpgcheck \
    --repofrompath "terra,https://repos.fyralabs.com/terra${FEDORA_RELEASE}" \
    terra-release >/tmp/compose-last.log 2>&1 || return 1
  dnf5 -y install --enablerepo=terra \
    terra-release-extras terra-release-mesa terra-release-multimedia \
    terra-release-nvidia >/tmp/compose-last.log 2>&1 || return 1
}

bootstrap_terra() {
  say 'terra bootstrap (incl. nvidia subrepo)'
  retry 6 terra _terra_once || die 'Terra bootstrap failed'
  disable_yum_repos /etc/yum.repos.d/*terra*.repo
}

bootstrap_fusion() {
  say 'rpmfusion bootstrap'
  retry 6 fusion dnf5 -y install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_RELEASE}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_RELEASE}.noarch.rpm" \
    || die 'RPMFusion bootstrap failed'
  disable_yum_repos /etc/yum.repos.d/rpmfusion*.repo
}

# Swap the Fedora kernel set for CachyOS LTO. Leaves $KVER exported.
swap_kernel_cachyos() {
  say 'kernel: fedora -> cachyos-lto'
  stub_kernel_install_hooks
  trap restore_kernel_install_hooks ERR
  dnf5 -y install jq >/tmp/compose-last.log 2>&1 || die 'jq install failed'
  local pkg
  for pkg in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra; do
    if have_rpm "${pkg}"; then rpm --erase "${pkg}" --nodeps; fi
  done
  rm -rf /usr/lib/modules/*
  install_cachyos_kernel
  rpm -q kernel-cachyos-lto-core >/dev/null || die 'kernel-cachyos-lto-core missing after COPR install'
  KVER=$(rpm -q kernel-cachyos-lto-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | LC_ALL=C sort -V | tail -n1)
  [[ -n "${KVER}" ]] || die 'cannot determine installed CachyOS kernel version'
  echo "kver: ${KVER}"
  find /lib/modules -mindepth 1 -maxdepth 1 ! -name "${KVER}" -exec rm -rf {} +
}

# NVIDIA driver stack from terra-nvidia + kmod built for the CachyOS kernel.
# Leaves the build toolchain installed: akmod RPMs hard-require gcc/make and
# the LTO kernel needs clang/lld for every kmod build (incl. image updates).
install_nvidia_terra() {
  say 'nvidia stack (terra-nvidia) + kmod'
  dnf5 -y install gcc make clang llvm lld >/tmp/compose-last.log 2>&1 || die 'kmod toolchain failed'
  dnf5 -y install akmods >/tmp/compose-last.log 2>&1 || die 'akmods tooling failed'
  fix_akmods_ostree_post
  retry 6 nvidia dnf5 -y install "${TERRA_NVIDIA_REPOS[@]/#/--enablerepo=}" \
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
    nvidia-driver-selinux \
    || die 'nvidia stack install failed'
  build_kmod nvidia 'nvidia.ko*' "${KVER}" 'nvidia-kmod-*.src.rpm'
  apply_selinux_game_booleans
  rm -f /usr/share/vulkan/icd.d/nouveau_icd.*.json
  if [[ -e /usr/lib64/libnvidia-ml.so.1 ]]; then ln -sf libnvidia-ml.so.1 /usr/lib64/libnvidia-ml.so; fi
  depmod -a "${KVER}"
  restore_kernel_install_hooks
  trap - ERR
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
  dnf5 -y install libva-nvidia-driver.x86_64 libva-nvidia-driver.i686 >/tmp/compose-last.log 2>&1 ||
    die 'libva-nvidia-driver failed'
  install_priority vulkan-loader.x86_64 vulkan-loader.i686 vulkan-tools
}

# BetterBird: latest x86_64 tarball fetched on the CI host into the build
# context; installed here from disk (no network in the container).
install_betterbird() {
  say 'betterbird (latest, host-fetched)'
  local tarball ver
  tarball=$(find /ctx/_build/betterbird -name 'betterbird-*.en-US.linux-x86_64.tar.xz' -print -quit 2>/dev/null || true)
  [[ -n ${tarball} ]] || die 'BetterBird tarball missing under /ctx/_build/betterbird'
  ver=$(basename "${tarball}" .en-US.linux-x86_64.tar.xz)
  rm -rf /opt/betterbird
  tar -xJf "${tarball}" -C /opt
  mv /opt/betterbird "/opt/${ver}"
  ln -sfn "/opt/${ver}" /opt/betterbird
  mkdir -p /usr/local/bin
  ln -sfn "/opt/${ver}/betterbird" /usr/local/bin/betterbird
  install -D -m 0644 "/opt/${ver}/chrome/icons/default/default256.png" \
    /usr/share/icons/hicolor/256x256/apps/betterbird.png
  install -D -m 0644 "/opt/${ver}/chrome/icons/default/default64.png" \
    /usr/share/icons/hicolor/64x64/apps/betterbird.png
  [[ -x "/opt/${ver}/betterbird" ]] || die "BetterBird ${ver}: binary missing after install"
  echo "betterbird: ${ver}"
}

# Zen Browser: latest official release tarball, host-fetched like BetterBird.
install_zen() {
  say 'zen browser (latest, host-fetched)'
  local tarball icon
  tarball=$(find /ctx/_build/zen -name 'zen.linux-x86_64.tar.*' -print -quit 2>/dev/null || true)
  [[ -n ${tarball} ]] || die 'Zen tarball missing under /ctx/_build/zen'
  rm -rf /opt/zen
  mkdir -p /opt/zen
  tar -xaf "${tarball}" -C /opt/zen
  [[ -x /opt/zen/zen/zen ]] || die 'Zen: binary missing after install'
  icon=$(find /opt/zen/zen/chrome/icons -name 'default*.png' 2>/dev/null | LC_ALL=C sort -V | tail -n1)
  [[ -n ${icon} ]] || die 'Zen: icon missing after install'
  install -D -m 0644 "${icon}" /usr/share/icons/hicolor/256x256/apps/zen.png
  mkdir -p /usr/local/bin
  ln -sfn /opt/zen/zen/zen /usr/local/bin/zen-browser
  echo "zen: ${tarball##*/}"
}

# proton-cachyos: latest GitHub release asset (floats; HTTPS-only integrity,
# upstream publishes per-asset hashes inconsistently — vdf gate stays).
install_proton_latest() {
  say 'proton-cachyos (latest release)'
  local api tag url dest=/usr/share/steam/compatibilitytools.d
  api=$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors \
    https://api.github.com/repos/CachyOS/proton-cachyos/releases/latest) || die 'proton latest lookup failed'
  url=$(echo "${api}" | jq -r '.assets[] | select(.name | test("x86_64\\.tar\\.(xz|zst)$")) | .browser_download_url' | head -n1)
  [[ -n ${url} && ${url} != null ]] || die 'proton x86_64 asset missing in latest release'
  tag=$(echo "${api}" | jq -r '.tag_name')
  echo "proton: ${tag} ${url##*/}"
  dnf5 -y install tar xz curl jq >/tmp/compose-last.log 2>&1 || die 'proton fetch deps failed'
  mkdir -p /tmp/proton-cachyos "${dest}"
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "/tmp/proton-cachyos/pkg" "${url}" ||
    die 'proton download failed'
  tar -xaf /tmp/proton-cachyos/pkg -C "${dest}"
  [[ -n $(find "${dest}" -name compatibilitytool.vdf -print -quit) ]] ||
    die 'proton tarball missing compatibilitytool.vdf'
  rm -rf /tmp/proton-cachyos
}

# Latest tag of a GitHub repo (vX.Y.Z tags preferred, else default-branch HEAD).
github_latest_tag() {
  local repo=$1 tag
  tag=$(git ls-remote --tags "https://github.com/${repo}" 2>/dev/null |
    grep -oE 'refs/tags/v[0-9][0-9A-Za-z._-]*(\^\{\})?$' |
    grep -oE 'v[0-9][0-9A-Za-z._-]*' | LC_ALL=C sort -V | tail -n1)
  if [[ -z ${tag} ]]; then
    tag=$(git ls-remote --symref "https://github.com/${repo}" HEAD 2>/dev/null |
      grep -oE 'refs/heads/[^[:space:]]+' | head -n1)
    [[ -n ${tag} ]] || die "cannot resolve latest ref for ${repo}"
    echo "branch:${tag#refs/heads/}"
  else
    echo "tag:${tag}"
  fi
}

# oo7 Secret Service stack, cargo-built at the latest tag (Fedora ships only
# oo7-cli; daemon/portal/PAM needed for wl/sericea keyring).
install_oo7() {
  if command -v oo7-daemon >/dev/null 2>&1 && [[ -e /usr/lib/security/pam_oo7.so ]]; then return 0; fi
  say 'oo7 (latest tag, cargo)'
  local ref kind
  ref=$(github_latest_tag linux-credentials/oo7)
  kind=${ref%%:*} ref=${ref#*:}
  echo "oo7: ${kind} ${ref}"
  dnf5 -y install git rust cargo gcc pkgconf-pkg-config >/tmp/compose-last.log 2>&1 || die 'oo7 toolchain failed'
  rm -rf /tmp/oo7
  git init -q /tmp/oo7
  git -C /tmp/oo7 remote add origin https://github.com/linux-credentials/oo7
  if [[ ${kind} == tag ]]; then
    git -C /tmp/oo7 fetch --depth 1 origin "${ref}" || die 'oo7 fetch failed'
  else
    git -C /tmp/oo7 fetch --depth 1 origin "${ref}" || die 'oo7 fetch failed'
  fi
  git -C /tmp/oo7 checkout -q FETCH_HEAD
  (
    cd /tmp/oo7
    CARGO_HOME=/tmp/oo7-cargo cargo build --release --locked \
      -p oo7-daemon -p oo7-cli -p oo7-portal -p oo7-pam -p cargo-credential-oo7 2>/tmp/oo7-build.log ||
      CARGO_HOME=/tmp/oo7-cargo cargo build --release \
        -p oo7-daemon -p oo7-cli -p oo7-portal -p oo7-pam -p cargo-credential-oo7
  ) || { tail -n 25 /tmp/oo7-build.log >&2; die 'oo7 cargo build failed'; }
  install -D -m 0755 /tmp/oo7/target/release/oo7-daemon /usr/bin/oo7-daemon
  install -D -m 0755 /tmp/oo7/target/release/oo7-cli /usr/bin/oo7-cli
  install -D -m 0755 /tmp/oo7/target/release/cargo-credential-oo7 /usr/bin/cargo-credential-oo7
  setcap cap_ipc_lock=+ep /usr/bin/oo7-daemon 2>/dev/null || true
  install -D -m 0755 /tmp/oo7/target/release/libpam_oo7.so /usr/lib/security/pam_oo7.so
  install -D -m 0755 /tmp/oo7/target/release/oo7-portal /usr/lib/oo7-portal
  install -D -m 0644 /dev/stdin /usr/share/xdg-desktop-portal/portals/oo7-portal.portal <<'EOF'
[Portal]
name=oo7
description=Secret service portal (oo7)
busname=org.freedesktop.impl.portal.Secret
main-binary=/usr/lib/oo7-portal
UseIn=hyprland,sway
EOF
  rm -rf /tmp/oo7 /tmp/oo7-cargo /tmp/oo7-build.log
  dnf5 -y remove rust cargo >/tmp/compose-last.log 2>&1 || true
  command -v oo7-daemon >/dev/null || die 'oo7 build produced no daemon'
}

# wl-clip-persist, cargo-built at the latest tag (no RPM anywhere).
install_wl_clip_persist() {
  if command -v wl-clip-persist >/dev/null 2>&1; then return 0; fi
  if install_priority wl-clip-persist; then return 0; fi
  say 'wl-clip-persist (latest tag, cargo)'
  local ref kind
  ref=$(github_latest_tag Linus789/wl-clip-persist)
  kind=${ref%%:*} ref=${ref#*:}
  echo "wl-clip-persist: ${kind} ${ref}"
  dnf5 -y install rust cargo gcc wayland-devel libxkbcommon-devel pkgconf-pkg-config >/tmp/compose-last.log 2>&1 ||
    die 'wl-clip-persist toolchain failed'
  rm -rf /tmp/wl-clip-persist
  git init -q /tmp/wl-clip-persist
  git -C /tmp/wl-clip-persist remote add origin https://github.com/Linus789/wl-clip-persist.git
  git -C /tmp/wl-clip-persist fetch --depth 1 origin "${ref}" || die 'wl-clip-persist fetch failed'
  git -C /tmp/wl-clip-persist checkout -q FETCH_HEAD
  (
    cd /tmp/wl-clip-persist
    CARGO_HOME=/tmp/cargo cargo build --release --locked 2>/tmp/wlp-build.log ||
      CARGO_HOME=/tmp/cargo cargo build --release
  ) || { tail -n 25 /tmp/wlp-build.log >&2; die 'wl-clip-persist cargo build failed'; }
  install -D -m 0755 /tmp/wl-clip-persist/target/release/wl-clip-persist /usr/bin/wl-clip-persist
  rm -rf /tmp/wl-clip-persist /tmp/cargo /tmp/wlp-build.log
  dnf5 -y remove rust cargo wayland-devel libxkbcommon-devel >/tmp/compose-last.log 2>&1 || true
  command -v wl-clip-persist >/dev/null || die 'wl-clip-persist build produced no binary'
}

# Final refresh upgrade across the ladder (Terra/Fusion explicitly enabled;
# COPRs and foreign repos stay dead — RC-1). Filtered output: problems and
# skips stay visible, progress bars do not.
final_upgrade() {
  say 'final refresh upgrade (ladder repos only)'
  local rc=0
  dnf5 -y --refresh upgrade \
    "${TERRA_REPOS[@]/#/--enablerepo=}" \
    "${TERRA_NVIDIA_REPOS[@]/#/--enablerepo=}" \
    "${FUSION_REPOS[@]/#/--enablerepo=}" \
    --exclude openrazer-kernel-modules-dkms >/tmp/upgrade.log 2>&1 || rc=$?
  grep -aE 'Problem|cannot install|conflict|Skipping packages|Error|error:|No match|Removing [a-z]' /tmp/upgrade.log || true
  tail -n 4 /tmp/upgrade.log
  [[ ${rc} == 0 ]] || die "refresh upgrade failed (rc=${rc})"
}

# Boot-critical smoke checks. fail=1 accumulates; die at the end.
SMOKE_FAIL=0
smoke() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "ok: ${name}"
  else
    echo "SMOKE-FAIL: ${name}" >&2
    SMOKE_FAIL=1
  fi
}
smoke_done() {
  if [[ ${SMOKE_FAIL} != 0 ]]; then die 'smoke checks failed'; fi
  echo 'smoke checks passed'
}
