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

# akmods 0.6.2 (F44) regression: the akmod-nvidia %post scriptlet invokes
# /usr/sbin/akmods-ostree-post, which calls akmodsbuild directly as root.
# akmodsbuild 0.6.2 refuses to run as root ("Not to be used as root; start
# as user or 'akmodsbuild' instead"), the scriptlet fails, and dnf5 marks
# the whole install transaction failed. The main akmods script already
# carries the upstream privilege-drop pattern: chown the build tmpdir to
# the akmods user, unset TMPDIR (misused by runuser, rfbz#2596), then run
# akmodsbuild via runuser as the akmods user. Apply the same pattern to
# the ostree-post helper so the kmod builds correctly during dnf5 install.
# Must run before the dnf5 transaction that installs akmod-nvidia.
fix_akmods_ostree_post() {
  local ostree_post=/usr/sbin/akmods-ostree-post
  [[ -f ${ostree_post} ]] || return 0
  if grep -q 'runuser' "${ostree_post}"; then
    return 0
  fi
  # Env prefix on the akmodsbuild invocation. Two layers pick the toolchain:
  #  1. The NVIDIA kernel-open Makefile (nvidia kmod only) does
  #     `CC ?= cc` / `LD ?= ld` and then launches the kernel sub-make with
  #     "CC=$(CC)" "LD=$(LD)" on the make command line (command line beats
  #     the kernel Makefile's own assignments). With no env CC it falls
  #     back to the kernel .config's CONFIG_CC_VERSION_TEXT (clang), but
  #     LD always defaults to `ld` (bfd) -> the module links die on the
  #     LTO config's `-mllvm` flag ("unrecognised emulation mode: llvm").
  #     So CC=clang and LD=ld.lld env vars are REQUIRED for nvidia.
  #     (Plain-kernel modules like openrazer don't go through that Makefile:
  #     there, Makefile assignments override env CC/LD, which is why
  #     LLVM=1 is still needed - see 2.)
  #  2. The kernel Makefile selects its own toolchain from LLVM:
  #     `ifneq ($(LLVM),)` -> CC=clang, LD=ld.lld, AR=llvm-ar, ...
  #     else CC=gcc, LD=ld. LLVM=1 makes that block clang+lld (and the
  #     llvm-* binutils), matching the clang+LTO x86_64_v3 kernel whose
  #     saved CFLAGS carry clang-only options (-mstack-alignment=8,
  #     -mretpoline-external-thunk, -fexperimental-late-parse-attributes,
  #     -fsplit-lto-unit), and lets ld.lld handle the LTO config's
  #     unconditional `-mllvm -import-instr-limit=5` natively (ld.bfd
  #     parses -mllvm as `-m llvm` = --emulation and dies).
  #  KCFLAGS="-fno-lto -fno-split-lto-unit": the kernel CFLAGS enable thin
  #    LTO (-flto=thin -fsplit-lto-unit), which would make the module .o
  #    files LLVM bitcode. KCFLAGS is appended by the kernel Makefile
  #    after the kernel CFLAGS, so -fno-lto wins and the module objects
  #    are plain ELF again (non-LTO modules against an LTO kernel is the
  #    standard supported combination).
  #  MAKEFLAGS="-j$(nproc)": parallel kernel-module make ($(nproc) expands
  #    at scriptlet runtime, i.e. the build container's core count).
  # Note: '&' is special in the sed replacement (it means "the match"), so
  # the shell '&&' chain must be written as '\&\&' here.
  if ! sed -E -i '0,/^([[:space:]]*)akmodsbuild /s||\1chown akmods "${tmpdir}" "${tmpdir}results" \&\& unset TMPDIR \&\& CC=clang LD=ld.lld LLVM=1 KCFLAGS="-fno-lto -fno-split-lto-unit" MAKEFLAGS="-j$(nproc)" /usr/sbin/runuser -u akmods -- /usr/bin/akmodsbuild |' "${ostree_post}"; then
    die "failed to patch ${ostree_post}"
  fi
  grep -q '/usr/sbin/runuser' "${ostree_post}" || die "akmods-ostree-post privilege-drop patch did not apply"
  bash -n "${ostree_post}" || die "patched ${ostree_post} failed syntax check"
}

# Install the CachyOS kernel set from COPR over the Fedora kernel set.
# Base set (kernel-cachyos + devel-matched) is fatal; modules-extra and the
# unmatched devel are best-effort so a renamed subpackage cannot fail the
# whole compose. The COPR is disabled again before returning, even when the
# install fails. Requires stubbed kernel-install hooks in this unbooted tree.
install_cachyos_kernel() {
  local rc=0 attempt
  # COPR's results storage intermittently 504s on metadata fetch (observed
  # 2026-09-03), so retry the install like the Terra bootstrap does; dnf5
  # only caches successful metadata, so each attempt re-fetches it.
  dnf5 -y copr enable "${CACHYOS_COPR}"
  for attempt in 1 2 3 4 5 6; do
    dnf5 -y install kernel-cachyos-lto kernel-cachyos-lto-devel-matched && rc=0 && break
    rc=$?
    if ((attempt < 6)); then
      echo "kernel-cachyos-lto install attempt ${attempt}/6 failed (rc=${rc}); retrying in 15s" >&2
      sleep 15
    fi
  done
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

# SELinux gaming setup: the booleans Proton/Wine gaming needs (JIT module
# loading, JIT execmem, cheap execmem) plus domain_kernel_load_modules for
# the akmod-built nvidia module. `semanage boolean -m --on` changes the
# policy default (preferred); `setsebool -P ... 1` persists the current
# value (fallback). Each boolean is applied independently and is
# non-fatal with a warning so one unavailable boolean cannot block the rest.
apply_selinux_game_booleans() {
  local b
  for b in selinuxuser_execmod selinuxuser_execstack selinuxuser_execheap domain_kernel_load_modules; do
    if command -v semanage >/dev/null 2>&1 && semanage boolean -m --on "${b}" >/dev/null 2>&1; then
      continue
    fi
    setsebool -P "${b}" 1 2>/dev/null || echo "SELinux boolean ${b} unavailable" >&2
  done
  return 0
}

# ---------------------------------------------------------------------------
# BetterBird (betterbird.eu) — Thunderbird fork. Not in any Fedora repo, so
# the LATEST x86_64 release is pulled at compose time (weekly CI rebuilds =
# always current on the published image). The official download site is an
# auto-generated file listing; the current release of each ESR line carries
# a "-latest-" marker, which we prefer. The project publishes no checksums
# (verified 2026-09), so integrity rests on HTTPS from betterbird.eu; the
# build fails closed on any download/extract error or missing binary.
# Official sources for the same file set, in preference order:
# BetterBird's BunnyCDN bulk-download mirror first — a CDN built for
# exactly this (the origin sits on small shared hosting that
# intermittently drops connections from datacenter/CI networks) — and
# the origin as canonical fallback. Identical listing verified 2026-09-03.
readonly BETTERBIRD_SOURCES=(
  'https://betterbird-downloads.b-cdn.net'
  'https://www.betterbird.eu/downloads'
)

install_betterbird() {
  local listing files url ver base base2
  listing=''
  for base in "${BETTERBIRD_SOURCES[@]}"; do
    # --max-time caps each attempt (the source can drop the connection
    # silently; a stalled read must not run the whole retry budget).
    if listing=$(curl -fsSL --proto '=https' --max-time 60 --retry 2 --retry-all-errors --retry-delay 5 --retry-max-time 150 --connect-timeout 30 "${base}/" 2>/tmp/bb-listing.err); then
      break
    fi
    echo "BetterBird: listing fetch failed from ${base} (last error: $(tail -n1 /tmp/bb-listing.err 2>/dev/null)); trying next source" >&2
  done
  if [[ -z ${listing} ]]; then
    echo '--- listing fetch errors (last attempt) ---' >&2
    cat /tmp/bb-listing.err 2>/dev/null || true
    die 'BetterBird: listing fetch failed from all sources'
  fi
  # Current release of each ESR line first ("-latest-" marker), then every
  # plain en-US x86_64 build. Exclude the Previous/ archive; highest
  # version wins.
  files=$(grep -oE 'LinuxArchive/betterbird-[^"]*-latest-[^"]*\.en-US\.linux-x86_64\.tar\.xz' <<<"${listing}" | grep -v 'Previous/' | LC_ALL=C sort -V || true)
  if [[ -z ${files} ]]; then
    files=$(grep -oE 'LinuxArchive/betterbird-[^"]*\.en-US\.linux-x86_64\.tar\.xz' <<<"${listing}" | grep -vE 'Previous/|-latest-' | LC_ALL=C sort -V || true)
  fi
  [[ -n ${files} ]] || die 'BetterBird: no x86_64 tarball found in the download listing'
  base2=''
  for base2 in "${BETTERBIRD_SOURCES[@]}"; do
    [[ ${base2} != ${base} ]] && break
  done
  url="${base}/$(tail -n1 <<<"${files}")"
  ver=$(basename "${url}" .en-US.linux-x86_64.tar.xz)
  if ! curl -fsSL --proto '=https' --retry 2 --retry-all-errors --retry-delay 10 --retry-max-time 900 --connect-timeout 30 --max-time 900 -o /tmp/betterbird.tar.xz "${url}" 2>/tmp/bb-dl.err; then
    echo "BetterBird: tarball download failed from ${base} (last error: $(tail -n1 /tmp/bb-dl.err 2>/dev/null)); retrying via ${base2}" >&2
    curl -fsSL --proto '=https' --retry 2 --retry-all-errors --retry-delay 10 --retry-max-time 900 --connect-timeout 30 --max-time 900 -o /tmp/betterbird.tar.xz "${base2}/$(tail -n1 <<<"${files}")" 2>>/tmp/bb-dl.err || {
      echo '--- tarball download errors ---' >&2
      tail -n 20 /tmp/bb-dl.err >&2 || true
      die 'BetterBird: tarball download failed from all sources'
    }
  fi
  rm -rf /opt/betterbird
  tar -xJf /tmp/betterbird.tar.xz -C /opt
  mv /opt/betterbird "/opt/${ver}"
  ln -sfn "/opt/${ver}" /opt/betterbird
  # /usr/local is a symlink to the writable /var/usrlocal in the image.
  mkdir -p /usr/local/bin
  ln -sfn "/opt/${ver}/betterbird" /usr/local/bin/betterbird
  # Icon for the .desktop entry (shipped in system_files); the tarball has
  # no desktop file of its own.
  install -D -m 0644 "/opt/${ver}/chrome/icons/default/default256.png" \
    /usr/share/icons/hicolor/256x256/apps/betterbird.png
  install -D -m 0644 "/opt/${ver}/chrome/icons/default/default64.png" \
    /usr/share/icons/hicolor/64x64/apps/betterbird.png
  rm -f /tmp/betterbird.tar.xz
  [[ -x "/opt/${ver}/betterbird" ]] || die "BetterBird ${ver}: binary missing after install"
  echo "BetterBird ${ver} installed (latest x86_64 release)"
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

# ---------------------------------------------------------------------------
# oo7 — Rust implementation of the D-Bus Secret Service
# (org.freedesktop.secrets); the wl/sericea images' keyring, replacing
# gnome-keyring.
#
# Fedora 44's repos ship only oo7-cli 0.4.3 (no daemon, portal, or PAM
# module), so the full stack is source-built at a pinned tag:
#   /usr/bin/oo7-daemon            user-session daemon (auto_start below
#                                  hardcodes this exact path)
#   /usr/bin/oo7-cli               manual unlock/lock from the terminal
#   /usr/bin/cargo-credential-oo7  cargo credential provider
#   /usr/lib/security/pam_oo7.so   login auto-unlock + password sync
#   /usr/lib/oo7-portal            XDG portal Secret backend
# PAM wiring (auth/session/password lines) is added at first boot by the
# ryven-keyring-pam oneshot; the user unit + generator in system_files keep
# the daemon running per session. Build-only toolchain packages are removed
# again so they do not ship in the final image.
#
# Source: https://github.com/linux-credentials/oo7
readonly OO7_TAG='0.6.0'
# Pinned tag commit; bump OO7_TAG and OO7_COMMIT together.
readonly OO7_COMMIT='9070389f33bec2e47048384e2fdbd7aab64e0df7'

install_oo7() {
  if command -v oo7-daemon >/dev/null 2>&1 && [[ -e /usr/lib/security/pam_oo7.so ]]; then
    return 0
  fi
  dnf5 -y install git rust cargo gcc pkgconf-pkg-config
  rm -rf /tmp/oo7
  git init -q /tmp/oo7
  git -C /tmp/oo7 remote add origin https://github.com/linux-credentials/oo7
  git -C /tmp/oo7 fetch --depth 1 origin "${OO7_COMMIT}"
  git -C /tmp/oo7 checkout -q FETCH_HEAD
  (
    cd /tmp/oo7
    CARGO_HOME=/tmp/oo7-cargo cargo build --release --locked \
      -p oo7-daemon -p oo7-cli -p oo7-portal -p oo7-pam -p cargo-credential-oo7
  )
  install -D -m 0755 /tmp/oo7/target/release/oo7-daemon /usr/bin/oo7-daemon
  install -D -m 0755 /tmp/oo7/target/release/oo7-cli /usr/bin/oo7-cli
  install -D -m 0755 /tmp/oo7/target/release/cargo-credential-oo7 /usr/bin/cargo-credential-oo7
  # Let the daemon mlock the keyring past the default 8 MiB rlimit. Best
  # effort: an unprivileged compose container may lack CAP_SETFCAP, in which
  # case the daemon runs with the plain rlimit.
  setcap cap_ipc_lock=+ep /usr/bin/oo7-daemon 2>/dev/null || true
  install -D -m 0755 /tmp/oo7/target/release/libpam_oo7.so /usr/lib/security/pam_oo7.so
  install -D -m 0755 /tmp/oo7/target/release/oo7-portal /usr/lib/oo7-portal
  # Upstream's .portal advertises UseIn=gnome only; ours targets the shells
  # running on this image so the portal backend is selected without a
  # portals.conf override.
  install -D -m 0644 /dev/stdin /usr/share/xdg-desktop-portal/portals/oo7-portal.portal <<'EOF'
[Portal]
name=oo7
description=Secret service portal (oo7)
busname=org.freedesktop.impl.portal.Secret
main-binary=/usr/lib/oo7-portal
UseIn=hyprland,sway
EOF
  rm -rf /tmp/oo7 /tmp/oo7-cargo
  dnf5 -y remove rust cargo gcc pkgconf-pkg-config
  command -v oo7-daemon >/dev/null || die 'oo7 build produced no daemon'
}
