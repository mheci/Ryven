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
# terra-release-nvidia is never installed. NVIDIA kernel modules are built
# for the CachyOS kernel from RPMFusion akmod-nvidia at compose time.
# CUDA toolkit packages are excluded; the driver's CUDA runtime libs
# (xorg-x11-drv-nvidia-cuda*) are part of the driver stack and do ship.
# Third-party .repo files stay on the image but must be enabled=0 at rest;
# compose re-enables them with --enablerepo.
# Never `dnf swap mesa-*-freeworld --allowerasing`. Never kernel versionlock.

set -euxo pipefail

# Fedora major used in Fusion/Terra URL paths. Bump Fusion, Terra, and the
# Containerfile FROM together when leaving 44.
readonly FEDORA_RELEASE=44
# Repo ID lists for dnf5 --enablerepo. One flag per repo: dnf5 does not accept
# a comma-separated list in a single --enablerepo flag, so callers must expand
# these arrays as "${TERRA_REPOS[@]/#/--enablerepo=}". terra-extras is the
# extras subrepo from terra-release-extras (%package extras), not a product.
readonly -a TERRA_REPOS=(terra terra-extras terra-multimedia terra-mesa)
readonly -a FUSION_REPOS=(rpmfusion-free rpmfusion-free-updates rpmfusion-nonfree rpmfusion-nonfree-updates)
# Repos excluded from the NVIDIA driver transaction. Negativo17's
# fedora-multimedia repo (enabled on the base image) ships same-version
# driver packages under different names (nvidia-driver-common) that
# file-conflict during the transaction, so the driver stack resolves
# strictly from the 'fedora-nvidia' repo (added per Negativo17's
# instructions) + Fedora. Exact repo IDs only: dnf5 hard-errors on a
# --disablerepo pattern that matches nothing. Base defaults elsewhere are
# left untouched.
readonly -a NVIDIA_EXCLUDE_REPOS=(--disablerepo=fedora-multimedia)
# The NVIDIA driver stack comes from Negativo17 (repo ID fedora-nvidia,
# added via their repofile). RPMFusion is kept only for non-driver
# packages (ffmpeg, libdvdcss, generic i686 fallbacks in install_priority).
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

# systemctl is-enabled prints enabled|disabled|masked|static|…. Compare to
# the string enabled. Missing units are not enabled.
unit_enabled() {
  [[ "$(systemctl is-enabled "$1" 2>/dev/null || true)" == "enabled" ]]
}

# The ublue base image ships /usr/local as a placeholder in a
# non-directory form (a dangling symlink in base-main: `[[ -e ]]` is false
# but `cp -avf` still refuses to lay a directory over it). Replace it in
# any non-directory form before the copy.
if [[ ! -d /usr/local ]]; then
  rm -rf /usr/local
fi

# Overlay /ctx/system_files onto the image root. Paths here are the source of
# truth for kargs.d, environment.d, udev, sysctl, Plasma, justfiles, pixmaps.
cp -avf /ctx/system_files/. /

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

# RPM Fusion release RPMs drop /etc/yum.repos.d/rpmfusion-*.repo. Version in
# the URL must match FEDORA_RELEASE. Files are disabled after Terra bootstrap.
dnf5 -y install \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_RELEASE}.noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_RELEASE}.noarch.rpm"

# Terra bootstrap: --nogpgcheck + --repofrompath only until terra-release
# lands (it ships the FyraLabs signing keys and terra.repo). Retried because
# Terra publishes metadata non-atomically and mirrors can serve stale
# repomd files: a fresh repomd can reference files that 404, or fail its
# checksum, until the publish settles.
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

# Default-off: Fusion and all Terra repo files (terra, extras, mesa, multimedia).
disable_yum_repos /etc/yum.repos.d/rpmfusion*.repo /etc/yum.repos.d/*terra*.repo

# Install the CachyOS kernel set from COPR over the Fedora kernel set.
# Base set (kernel-cachyos-lto + devel-matched) is fatal; modules-extra and
# the unmatched devel are best-effort so a renamed subpackage cannot fail
# the whole compose. The COPR is disabled again before returning, even when
# the install fails. Requires stubbed kernel-install hooks in this unbooted
# tree.
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

# CachyOS kernel replace: LLVM-ThinLTO flavor (COPR
# bieszczaders/kernel-cachyos-lto, BORE scheduler). Requires x86_64_v3; see
# README hardware notes. The ublue ogc-44 kmod sets (xone, xpadneo,
# openrazer, ryzen_smu, zenergy) have no CachyOS builds and are dropped with
# this switch. Stub kernel-install first so rpm -e / dnf install of kernel
# packages does not invoke rpm-ostree plugins in this unbooted tree.
stub_kernel_install_hooks
trap restore_kernel_install_hooks ERR
dnf5 -y install jq

# Erase Fedora kernel Names (nodeps: CachyOS replaces them next). Keep
# kernel-tools*: Fedora userspace tools work across kernels and CachyOS
# ships no tools rebuild here. Wipe /usr/lib/modules BEFORE installing
# CachyOS so leftover Fedora .ko cannot confuse depmod; the wildcard must
# never run after the CachyOS tree lands.
local_pkg=
for local_pkg in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra; do
  if have_rpm "${local_pkg}"; then
    rpm --erase "${local_pkg}" --nodeps
  fi
done
rm -rf /usr/lib/modules/*

install_cachyos_kernel
rpm -q kernel-cachyos-lto-core >/dev/null ||
  die 'kernel-cachyos-lto-core missing after COPR install'

# Single kver string for depmod and nvidia .ko path checks. sort -V + tail if
# more than one kernel-cachyos-lto-core ever landed (should be one).
# rpmvercmp ordering is approximated with LC_ALL=C sort -V; an empty result
# is fatal so depmod never falls back to the host kernel.
KVER=$(rpm -q kernel-cachyos-lto-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | LC_ALL=C sort -V | tail -n1)
[[ -n "${KVER}" ]] || die 'cannot determine installed CachyOS kernel version'

# This script is self-contained (it does NOT source common.sh); the
# helpers below are local copies of the common.sh definitions used by the
# sections that follow.
#
# akmods 0.6.2 (F44) regression fix: the akmod-nvidia %post scriptlet
# invokes /usr/sbin/akmods-ostree-post, which calls akmodsbuild directly
# as root. akmodsbuild 0.6.2 refuses to run as root ("Not to be used as
# root; start as user or 'akmodsbuild' instead"), the scriptlet fails, and
# dnf5 fails the whole install transaction. The main akmods script already
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
  # Env prefix on the akmodsbuild invocation:
  #  CC=clang: the CachyOS LTO kernel tree is clang-built; its saved CFLAGS
  #    carry clang-only options, so the module must be built with the same
  #    compiler family as the kernel.
  #  KCFLAGS="-fno-lto -fno-split-lto-unit": the kernel CFLAGS enable thin
  #    LTO (-flto=thin -fsplit-lto-unit), which makes the .o files LLVM
  #    bitcode. NVIDIA's Kbuild partial-links them with `ld -r`, which cannot
  #    read bitcode ("file format not recognized"). KCFLAGS is appended by
  #    the kernel Makefile after the kernel CFLAGS, so -fno-lto wins and the
  #    module objects are plain ELF again. Non-LTO modules against an LTO
  #    kernel are the standard supported combination.
  #  MAKEFLAGS="-j$(nproc)": parallel kernel-module make ($(nproc) expands
  #    at scriptlet runtime, i.e. the build container's core count).
  # Note: '&' is special in the sed replacement (it means "the match"), so
  # the shell '&&' chain must be written as '\&\&' here.
  if ! sed -E -i '0,/^([[:space:]]*)akmodsbuild /s||\1chown akmods "${tmpdir}" "${tmpdir}results" \&\& unset TMPDIR \&\& CC=clang KCFLAGS="-fno-lto -fno-split-lto-unit" MAKEFLAGS="-j$(nproc)" /usr/sbin/runuser -u akmods -- /usr/bin/akmodsbuild |' "${ostree_post}"; then
    die "failed to patch ${ostree_post}"
  fi
  grep -q '/usr/sbin/runuser' "${ostree_post}" || die "akmods-ostree-post privilege-drop patch did not apply"
  bash -n "${ostree_post}" || die "patched ${ostree_post} failed syntax check"
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

# NVIDIA kernel modules built for the CachyOS kernel via RPMFusion akmod.
# The ublue prebuilt kmod-nvidia targets the OGC kernel and the CachyOS COPR
# ships no prebuilt NVIDIA modules (per COPR policy use RPMFusion or
# Negativo17), so the module is compiled here with
# kernel-cachyos-lto-devel-matched present. The LTO kernel tree is
# clang-built, so clang/llvm join the build deps. The result is unsigned:
# Secure Boot hosts must enroll their own MOK and sign it, or disable
# Secure Boot.
dnf5 -y install gcc make clang llvm
# Install the akmods tooling first: the akmod-nvidia %post (which runs
# inside the Negativo17 transaction below) invokes
# /usr/sbin/akmods-ostree-post, which only exists once the akmods package
# is in place.
dnf5 -y install akmods
# The akmod-nvidia %post builds the kmod inside that transaction; make the
# build work before the transaction runs (see fix_akmods_ostree_post).
fix_akmods_ostree_post
# Add the Negativo17 NVIDIA repo exactly as they instruct. The repofile
# defines the 'fedora-nvidia' repo; re-adding is idempotent (it overwrites
# the same file). Retried like the other flaky remote bootstraps.
for neg17_attempt in 1 2 3 4 5 6; do
  dnf5 -y config-manager addrepo \
    --from-repofile="https://negativo17.org/repos/fedora-nvidia.repo" && break
  [[ ${neg17_attempt} -lt 6 ]] || die 'Negativo17 addrepo failed after 6 attempts'
  echo "Negativo17 addrepo attempt ${neg17_attempt}/6 failed; retrying in 15s" >&2
  sleep 15
done
# NVIDIA driver stack from Negativo17 (their Fedora packaging, no version
# locks: the repo always serves the current driver release):
#  akmod-nvidia           kmod built by akmods (bundles the nvidia-kmod
#                         SRPM; its nvidia-kmod-common dep is pulled in)
#  nvidia-driver          meta: docs, nvidia-pcc, application profiles
#  xorg-x11-nvidia        X11 driver (nvidia_drv.so) + xorg.conf.d
#  nvidia-driver-libs     libEGL_nvidia, libGLES, VDPAU libvdpau_nvidia,
#                         Vulkan ICD + implicit layer (+.i686)
#  nvidia-driver-common   libnvidia-ml.so.1, nvidia-dbus.conf (+.i686)
#  nvidia-driver-cuda     nvidia-smi, CUDA MPS, OpenCL ICD
#  nvidia-driver-cuda-libs libcuda, nvcuvid, nvidia-encode, ptxjit,
#                         sandboxutils (+.i686)
#  nvidia-libXNVCtrl      XNVCtrl
#  nvidia-settings        configuration UI
#  nvidia-modprobe        udev device nodes
#  nvidia-persistenced    persistence daemon
#  libnvidia-fbc          Frame Buffer Capture (Steam) (+.i686)
#  nvidia-driver-selinux  SELinux policy module for the driver
# fedora-multimedia (enabled on the base image) ships same-version driver
# packages under different names that file-conflict during the
# transaction, so it stays disabled for this transaction only.
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
# KCFLAGS="-fno-lto -fno-split-lto-unit": the kernel CFLAGS enable thin LTO,
# which makes module .o files LLVM bitcode; NVIDIA's Kbuild partial-links
# them with `ld -r`, which cannot read bitcode. KCFLAGS is appended after
# the kernel CFLAGS, so the module objects are plain ELF (standard
# non-LTO-module-against-LTO-kernel combination).
# MAKEFLAGS: parallel make for the kernel-module build.
CC=clang KCFLAGS="-fno-lto -fno-split-lto-unit" MAKEFLAGS="-j$(nproc)" akmods --force --kernels "${KVER}"
if ! find "/usr/lib/modules/${KVER}" -name 'nvidia.ko*' -print -quit | grep -q .; then
  # Dump the akmod build log before failing so CI stdout shows the real
  # compiler error instead of just the missing .ko.
  echo '--- akmods log (last 40 lines) ---' >&2
  tail -n 40 /var/log/akmod/*.log 2>/dev/null || true
  die "akmods produced no nvidia.ko for ${KVER}"
fi
dnf5 -y remove gcc make clang llvm

# SELinux for gaming: Proton/Wine JIT + out-of-tree module loads.
# semanage boolean -m --on (policy default) with setsebool -P fallback.
apply_selinux_game_booleans

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

# VA-API for the NVIDIA driver (nvdec-vaapi-driver): libva-nvidia-driver
# is an official Fedora package again as of F44 (0.0.16) and only requires
# libEGL.so.1, so it installs cleanly next to the Negativo17 driver stack.
# Both ISAs (Steam 32-bit).
dnf5 -y install libva-nvidia-driver.x86_64 libva-nvidia-driver.i686
# vulkan-loader both ISAs from the priority ladder.
install_priority vulkan-loader.x86_64 vulkan-loader.i686 vulkan-tools

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
  firefox \
  # Text/OCR stack: spell checkers with English variants + Arabic
  # (hunspell covers ar; F44 has no aspell-ar package), c-ares for the
  # agentic toolchain, tesseract for Spectacle OCR.
  hunspell hunspell-en hunspell-en-US hunspell-en-GB hunspell-ar \
  aspell aspell-en gspell c-ares \
  tesseract tesseract-langpack-eng tesseract-langpack-ara \
  pciutils policycoreutils-python-utils power-profiles-daemon \
  # KDE minimum floor: device pairing on LAN, KIO virtual filesystems,
  # the Plasma 6 polkit agent (package is 'polkit-kde' on F44).
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

# scx-manager GUI from the CachyOS addons COPR (isolated: repo disabled
# again after install). On-demand alternative to the boot-enabled scx_loader.
copr_install_isolated bieszczaders/kernel-cachyos-addons scx-manager

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
install_priority falcond falcond-profiles
install_priority vicinae lact superfile
install_priority openrazer openrazer-daemon python3-openrazer
systemctl enable falcond.service lactd.service
if [[ -f /usr/lib/systemd/system/openrazer.service ]]; then
  systemctl enable openrazer.service
fi
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
# BetterBird (betterbird.eu) — Thunderbird fork. Not in any Fedora repo, so
# the LATEST x86_64 release is pulled at compose time (weekly CI rebuilds =
# always current on the published image). The official download site is an
# auto-generated file listing; the current release of each ESR line carries
# a "-latest-" marker, which we prefer. The project publishes no checksums
# (verified 2026-09), so integrity rests on HTTPS from betterbird.eu; the
# build fails closed on any download/extract error or missing binary.
# (Local copy of the common.sh definition; this script does not source it.)
readonly BETTERBIRD_BASE='https://www.betterbird.eu/downloads'

install_betterbird() {
  local listing files url ver
  listing=$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors "${BETTERBIRD_BASE}/")
  # Current release of each ESR line first ("-latest-" marker), then every
  # plain en-US x86_64 build. Exclude the Previous/ archive; highest
  # version wins.
  files=$(grep -oE 'LinuxArchive/betterbird-[^"]*-latest-[^"]*\.en-US\.linux-x86_64\.tar\.xz' <<<"${listing}" | grep -v 'Previous/' | LC_ALL=C sort -V || true)
  if [[ -z ${files} ]]; then
    files=$(grep -oE 'LinuxArchive/betterbird-[^"]*\.en-US\.linux-x86_64\.tar\.xz' <<<"${listing}" | grep -vE 'Previous/|-latest-' | LC_ALL=C sort -V || true)
  fi
  [[ -n ${files} ]] || die 'BetterBird: no x86_64 tarball found in the download listing'
  url="${BETTERBIRD_BASE}/$(tail -n1 <<<"${files}")"
  ver=$(basename "${url}" .en-US.linux-x86_64.tar.xz)
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o /tmp/betterbird.tar.xz "${url}"
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

# BetterBird: latest x86_64 release pulled at compose time (function
# above); desktop entry + icon ship in system_files.
install_betterbird
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
if ! install_priority gpu-screen-recorder; then
  copr_install_isolated brycensranch/gpu-screen-recorder-git gpu-screen-recorder
fi
install_priority bibata-cursor-theme klassy tela-icon-theme
[[ -f /usr/lib/systemd/system/bpftune.service ]] ||
   die 'bpftune-gaming missing bpftune.service'
systemctl enable bpftune.service ananicy-cpp.service

# Pinned CachyOS Proton SLR tarball. The .sha512sum asset is fetched over TLS
# from the same release and cross-checked against the PROTON_SHA512 value
# pinned below, so replacing both release assets cannot ship a tampered
# tarball. Fail if compatibilitytool.vdf is missing after extract (Steam will
# not list the tool). Not curl|sh.
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
check 'ffmpeg rpm' rpm -q ffmpeg
check 'libva-nvidia-driver' rpm -q libva-nvidia-driver
check 'zram generator disabled' bash -c '! systemctl is-enabled systemd-zram-setup@zram0.service 2>/dev/null | grep -qx enabled'
check 'no firefox flatpak' bash -c '! command -v flatpak >/dev/null || ! flatpak info --system org.mozilla.firefox >/dev/null 2>&1'
check 'ryven look-and-feel' test -f /usr/share/plasma/look-and-feel/org.ryven.desktop/metadata.json
check 'ryven color scheme' test -f /usr/share/color-schemes/Ryven.colors
check 'ryven dusk color scheme' test -f '/usr/share/color-schemes/Ryven Dusk.colors'
check 'ryven konsole scheme' test -f /usr/share/konsole/Ryven.colorscheme
check 'theme tokens' test -f /usr/share/ryven/themes/navy.json
check 'ryven wallpaper' test -f /usr/share/wallpapers/Ryven/contents/images/3840x2160.png
check 'ryven kdeglobals' grep -q 'LookAndFeelPackage=org.ryven.desktop' /etc/xdg/kdeglobals
check 'inter font default' grep -q 'font=Inter,' /etc/xdg/kdeglobals
check 'kde wallet (ksecretd)' command -v ksecretd
check 'pam-kwallet rpm' rpm -q pam-kwallet
check 'pam-kwallet module' test -f /usr/lib64/security/pam_kwallet5.so
check 'keyring pam oneshot' unit_enabled ryven-keyring-pam.service
# Minimum-functionality floor (all images): clipboard, OCR, notifications,
# KDE Connect OOTB, polkit, KIO, spell/OCR languages, yazi, encrypted DNS.
# KRunner (clipboard history) ships inside plasma-workspace on F44.
check 'clipboard manager (krunner)' test -x /usr/bin/krunner
check 'ocr: tesseract+eng+ara' bash -c 'rpm -q tesseract tesseract-langpack-eng tesseract-langpack-ara >/dev/null 2>&1'
check 'notifications (kf6-knotifications)' rpm -q kf6-knotifications
check 'kde-connect' rpm -q kde-connect
check 'kdeconnect firewall' unit_enabled ryven-kdeconnect-firewall.service
check 'polkit-kde agent' rpm -q polkit-kde
check 'kio-fuse' rpm -q kio-fuse
check 'kio-extras' rpm -q kio-extras
check 'spell: hunspell+en variants' bash -c 'rpm -q hunspell hunspell-en hunspell-en-US hunspell-en-GB >/dev/null 2>&1'
check 'spell: hunspell-ar' rpm -q hunspell-ar
check 'spell: aspell-en' rpm -q aspell-en
check 'spell: gspell' rpm -q gspell
check 'c-ares' rpm -q c-ares
check 'yazi' command -v yazi
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
