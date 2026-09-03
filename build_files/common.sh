#!/bin/bash
# Shared compose helpers for Ryven and Ryven-WL. Sourced, not executed.
# Callers must already have set -euxo pipefail or inherit it here.

# Fedora major used in Fusion/Terra URL paths. Bump Fusion, Terra, and the
# Containerfile FROM together when leaving 44.
readonly FEDORA_RELEASE=44
# Repo ID lists for dnf5 --enablerepo. One flag per repo: dnf5 does not accept
# a comma-separated list in a single --enablerepo flag, so callers must expand
# these arrays as "${TERRA_REPOS[@]/#/--enablerepo=}". terra-extras is the
# extras subrepo from terra-release-extras (%package extras), not a product.
readonly -a TERRA_REPOS=(terra terra-extras terra-multimedia terra-mesa)
readonly -a FUSION_REPOS=(rpmfusion-free rpmfusion-free-updates rpmfusion-nonfree rpmfusion-nonfree-updates)
# Repos excluded from NVIDIA driver transactions. Negativo17's
# fedora-multimedia repo (enabled on the base image) ships same-version
# driver packages under different names (nvidia-driver-common) that
# file-conflict with the RPMFusion xorg-x11-drv-nvidia set, so the driver
# stack resolves strictly from RPMFusion (+Fedora). Exact repo IDs only:
# dnf5 hard-errors on a --disablerepo pattern that matches nothing.
# Base defaults elsewhere are left untouched.
readonly -a NVIDIA_EXCLUDE_REPOS=(--disablerepo=fedora-multimedia)
# CachyOS kernel for Fedora: LLVM-ThinLTO flavor (COPR
# bieszczaders/kernel-cachyos-lto, BORE scheduler). Weekly rebuilds track the
# COPR tip; COPR offers no digest pins, so the tag is intentionally floating
# and the compose fails closed on install errors.
readonly CACHYOS_COPR='bieszczaders/kernel-cachyos-lto'
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
# Accepts literal paths or globs; non-matches are skipped via local nullglob.
disable_yum_repos() {
  local repo
  local nullglob_was_off=0
  shopt -q nullglob || nullglob_was_off=1
  shopt -s nullglob
  for repo in "$@"; do
    [[ -f ${repo} ]] || continue
    sed -i -E 's/^[[:space:]]*enabled[[:space:]]*=[[:space:]]*1([[:space:]]|$)/enabled=0\1/' "${repo}"
  done
  if ((nullglob_was_off)); then
    shopt -u nullglob
  fi
  return 0
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
    if dnf5 -y install "${TERRA_REPOS[@]/#/--enablerepo=}" "${pkg}"; then
      continue
    fi
    if dnf5 -y install "${FUSION_REPOS[@]/#/--enablerepo=}" "${pkg}"; then
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
    if dnf5 -y swap "${TERRA_REPOS[@]/#/--enablerepo=}" --allowerasing ffmpeg-free ffmpeg; then
      return 0
    fi
    if dnf5 -y swap "${FUSION_REPOS[@]/#/--enablerepo=}" --allowerasing ffmpeg-free ffmpeg; then
      return 0
    fi
  fi
  install_priority ffmpeg
}

# Enable a COPR, install listed packages, immediately disable the COPR repo
# file. The packages stay in rpmdb; later dnf on the host will not use COPR
# unless an admin re-enables it. The repo is disabled even when the install
# fails, so a failed compose never leaves the COPR enabled.
copr_install_isolated() {
  local copr=$1
  shift
  local rc=0
  dnf5 -y copr enable "${copr}"
  dnf5 -y install "$@" || rc=$?
  dnf5 -y copr disable "${copr}" || true
  return "${rc}"
}

# Add a vendor .repo from URL (overwrite if compose is re-run), install the
# remaining argv packages, then disable matching repo files so they are not
# default-on. glob is a basename glob under /etc/yum.repos.d; it is expanded
# locally with nullglob so a non-match disables nothing instead of passing a
# literal pattern on.
vendor_repo_install() {
  local glob=$1
  local url=$2
  shift 2
  local rc=0
  local -a matches=()
  local nullglob_was_off=0
  shopt -q nullglob || nullglob_was_off=1
  shopt -s nullglob
  dnf5 -y config-manager addrepo --overwrite --from-repofile="${url}"
  dnf5 -y install "$@" || rc=$?
  matches=(/etc/yum.repos.d/"${glob}")
  if ((nullglob_was_off)); then
    shopt -u nullglob
  fi
  if ((${#matches[@]})); then
    disable_yum_repos "${matches[@]}"
  fi
  return "${rc}"
}

# Replace rpm-ostree/dracut kernel-install plugins with `exit 0` so dnf can
# replace kernel-core in an unbooted container. Restored after depmod.
# Runs in a subshell so the caller working directory is unchanged even on
# failure; pair with a trap on restore (see callers).
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
      if [[ -e ${f}.bak ]]; then
        mv -f "${f}.bak" "${f}"
      fi
    done
  )
}

# Install the CachyOS kernel set from COPR over the Fedora kernel set.
# Base set (kernel-cachyos + devel-matched) is fatal; modules-extra and the
# unmatched devel are best-effort so a renamed subpackage cannot fail the
# whole compose. The COPR is disabled again before returning, even when the
# install fails. Requires stubbed kernel-install hooks in this unbooted tree.
install_cachyos_kernel() {
  local rc=0
  dnf5 -y copr enable "${CACHYOS_COPR}"
  dnf5 -y install kernel-cachyos-lto kernel-cachyos-lto-devel-matched || rc=$?
  if ((rc == 0)); then
    dnf5 -y install kernel-cachyos-lto-modules-extra || \
      echo 'kernel-cachyos-lto-modules-extra unavailable; continuing without it' >&2
    dnf5 -y install kernel-cachyos-lto-devel || \
      echo 'kernel-cachyos-lto-devel unavailable; continuing without it' >&2
  fi
  dnf5 -y copr disable "${CACHYOS_COPR}" || true
  return "${rc}"
}

# systemctl is-enabled prints enabled|disabled|masked|static|…. Compare to
# the string enabled. Missing units are not enabled.
unit_enabled() {
  [[ "$(systemctl is-enabled "$1" 2>/dev/null || true)" == "enabled" ]]
}

# wl-clip-persist is not in Fedora/Terra/Fusion (2026-09). RPM first, then
# a pinned-commit cargo build into /usr/bin. Build-only toolchain packages
# are removed again so they do not ship in the final image. Not curl|sh.
# Pinned upstream commit (tag v0.5.0); bump together with the fetch below.
readonly WL_CLIP_PERSIST_SHA='e26fde01c13922e3a65049dafb7d5adfbc52626e'
install_wl_clip_persist() {
  if command -v wl-clip-persist >/dev/null 2>&1; then
    return 0
  fi
  if install_priority wl-clip-persist; then
    return 0
  fi
  dnf5 -y install rust cargo gcc wayland-devel libxkbcommon-devel pkgconf-pkg-config
  rm -rf /tmp/wl-clip-persist
  git init -q /tmp/wl-clip-persist
  git -C /tmp/wl-clip-persist remote add origin https://github.com/Linus789/wl-clip-persist.git
  git -C /tmp/wl-clip-persist fetch --depth 1 origin "${WL_CLIP_PERSIST_SHA}"
  git -C /tmp/wl-clip-persist checkout -q FETCH_HEAD
  (
    cd /tmp/wl-clip-persist
    CARGO_HOME=/tmp/cargo cargo build --release --locked
  )
  install -D -m 0755 /tmp/wl-clip-persist/target/release/wl-clip-persist \
    /usr/bin/wl-clip-persist
  rm -rf /tmp/wl-clip-persist /tmp/cargo
  dnf5 -y remove rust cargo gcc wayland-devel libxkbcommon-devel pkgconf-pkg-config
  command -v wl-clip-persist >/dev/null || die 'wl-clip-persist build produced no binary'
}
