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
#   Containers: podman + distrobox RPMs; DistroShelf via first-boot Flatpak.
#   zswap on / zram off. No LIBVA_DRIVER_NAME=nvidia.
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
: >/tmp/compose-last.log  # fresh log per compose (this file is sourced once)

say() { echo "=== $*"; }
die() { echo "COMPOSE-FAIL: $*" >&2; exit 1; }
have_rpm() { rpm -q "$1" >/dev/null 2>&1; }
unit_enabled() { [[ "$(systemctl is-enabled "$1" 2>/dev/null || true)" == "enabled" ]]; }
require_src() { [[ -f "$1" ]] || die "overlay source missing: $1"; }

# Run quietly, appending to the log so failure tails show full history.
_q() { "$@" >>/tmp/compose-last.log 2>&1; }

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
  local id keep=' fedora updates updates-archive fedora-cisco-openh264 ' left
  for id in $(dnf5 repolist --all 2>/dev/null | awk 'NR > 1 {print $1}'); do
    if [[ ${keep} != *" ${id} "* ]]; then
      # NOTE: dnf5 spells these as subcommands (enable/disable), NOT the
      # dnf4-style --set-enabled/--set-disabled flags (silently errored here
      # before, leaving third-party repos enabled).
      dnf5 config-manager disable "${id}" || die "repo lockdown failed for ${id}"
    fi
  done
  # Fail closed: no non-Fedora repo may remain enabled at rest.
  left=$(dnf5 repolist --enabled 2>/dev/null | awk 'NR > 1 {print $1}') || die 'repo lockdown verify failed'
  [[ -n ${left} ]] || die 'repo lockdown: no repos enabled at all?!'
  for id in ${left}; do
    if [[ ${keep} != *" ${id} "* ]]; then
      die "repo lockdown incomplete: ${id} still enabled"
    fi
  done
  # Permanent proof in the log of the exact at-rest set.
  say "lockdown: enabled at rest: ${left//$'\n'/ }"
}

# dnf client-side speed tuning: fastest mirror + more parallel downloads.
# Pure client behavior; no repo content changes.
dnf_speed_tweaks() {
  mkdir -p /etc/dnf/dnf.conf.d
  printf '[main]\nfastestmirror=True\nmax_parallel_downloads=10\n' >/etc/dnf/dnf.conf.d/99-ryven-speed.conf
}

# First-boot Flathub oneshot: Flatpaks must persist on host /var, not in
# the ostree /usr. Writes the app list, the setup script, and a oneshot
# unit that installs from Flathub once (stamped, idempotent).
install_flatpak_firstboot() { # <flathub-app-id>...
  say "first-boot flatpaks ($*)"
  mkdir -p /usr/share/ryven /usr/libexec /usr/lib/systemd/system
  printf '%s\n' "$@" >/usr/share/ryven/flatpaks
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
}

# End-of-compose sequence: regenerate initramfs, fetch upstream configs, mask
# unwanted units, relocate build-time accounts, verify repo rest state, then
# drop caches and scratch. Order matters: the initramfs must be generated
# after the os-release IMAGE_ID edits in the build scripts.
final_cleanup() {
  regenerate_initramfs
  fetch_upstream_configs
  apply_service_masks
  relocate_build_accounts
  validate_repos_at_rest
  say 'final cleanup (caches, scratch)'
  dnf5 clean all >/dev/null 2>&1 || true
  rm -rf /tmp/* /var/tmp/* /var/log/dnf5.log 2>/dev/null || true
  rm -rf /boot/* 2>/dev/null || true
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

# Regenerate the initramfs deterministically: generic (never hostonly — the
# build runner's hardware is not the user's), reproducible, with ostree
# support. Dracut modules are probed, not assumed.
regenerate_initramfs() {
  say 'regenerate initramfs (generic, reproducible)'
  local kver="${KVER:-}" m mods=()
  if [[ -z ${kver} ]]; then
    kver=$(rpm -q kernel-cachyos-lto-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | LC_ALL=C sort -V | tail -n1 || true)
  fi
  [[ -n ${kver} ]] || die 'cannot determine kernel version for initramfs'
  for m in ostree fido2; do
    if dracut --list-modules 2>/dev/null | grep -qx "${m}"; then mods+=(--add "${m}"); fi
  done
  dracut --no-hostonly --kver "${kver}" --reproducible --zstd "${mods[@]}" \
    -f "/usr/lib/modules/${kver}/initramfs.img" >/tmp/compose-last.log 2>&1 ||
    { tail -n 25 /tmp/compose-last.log >&2 || true; die 'dracut regenerate failed'; }
  chmod 0600 "/usr/lib/modules/${kver}/initramfs.img"
}

# Small upstream config files with no RPM home: dxvk example config and the
# ublue distrobox preset inis. Best-effort (WARN, never fatal).
fetch_upstream_configs() {
  say 'upstream config files (dxvk example, distrobox presets)'
  mkdir -p /etc/distrobox
  retry 3 dxvk-conf curl -fsSL --proto '=https' --max-time 60 \
    -o /etc/dxvk-example.conf https://raw.githubusercontent.com/doitsujin/dxvk/master/dxvk.conf ||
    echo 'WARN: dxvk-example.conf fetch failed; continuing' >&2
  retry 3 distrobox-docker curl -fsSL --proto '=https' --max-time 60 \
    -o /etc/distrobox/docker.ini https://raw.githubusercontent.com/ublue-os/toolboxes/main/apps/docker/distrobox.ini ||
    echo 'WARN: distrobox docker.ini fetch failed; continuing' >&2
  retry 3 distrobox-incus curl -fsSL --proto '=https' --max-time 60 \
    -o /etc/distrobox/incus.ini https://raw.githubusercontent.com/ublue-os/toolboxes/main/apps/incus/distrobox.ini ||
    echo 'WARN: distrobox incus.ini fetch failed; continuing' >&2
}

# Mask units we never want active on first boot. Masking a missing unit is a
# harmless symlink; every call is guarded anyway.
apply_service_masks() {
  say 'mask unwanted units'
  systemctl mask flatpak-add-fedora-repos.service >/dev/null 2>&1 || true
  systemctl mask iscsi.service >/dev/null 2>&1 || true
  systemctl mask fedora-atomic-desktop-appstream-cache-refresh >/dev/null 2>&1 || true
}

# Move build-time accounts out of /etc into /usr (ostree-correct: /etc is
# 3-way-merged on upgrade, /usr is not). Port of ublue's finalize; fails
# closed when a moved entry does not persist.
relocate_accounts() { # <etc-file> <lib-file> <shadow-file> <keep-re> <reset-content>
  local etc="$1" lib="$2" shadow="$3" keep="$4" reset="$5"
  local out line name
  [[ -f ${etc} ]] || return 0
  out=$(grep -vE -- "${keep}" "${etc}") || true
  [[ -n ${out} ]] || return 0
  echo
  echo "Moving the following entries from ${etc} to ${lib}"
  echo "${out}"
  { cat "${lib}" 2>/dev/null || true; echo "${out}"; } >"${lib}.new"
  mv -f "${lib}.new" "${lib}"
  # Fail the build rather than ship an image where these went missing.
  while IFS= read -r line; do
    if ! grep -qxF -- "${line}" "${lib}"; then
      die "relocate: '${line}' did not persist in ${lib}"
    fi
  done <<<"${out}"
  printf '%s\n' "${reset}" >"${etc}"
  if [[ -f ${shadow} ]]; then
    while IFS= read -r line; do
      name="${line%%:*}"
      sed -i "/^${name}:/d" "${shadow}"
    done <<<"${out}"
  fi
}

relocate_build_accounts() {
  say 'relocate build-time accounts to /usr'
  relocate_accounts /etc/passwd /usr/lib/passwd /etc/shadow \
    'root' 'root:x:0:0:root:/root:/bin/bash'
  relocate_accounts /etc/group /usr/lib/group /etc/gshadow \
    'root|wheel' 'root:x:0:
wheel:x:10:'
  # Extra lock files created by container processes that might cause issues.
  rm -f /etc/.pwd.lock /etc/passwd- /etc/group- /etc/shadow- /etc/gshadow- /etc/subuid- /etc/subgid-
}

# Fail closed when any non-Fedora repo is still enabled at rest (an RPM
# installed mid-compose may drop an enabled .repo file). Mirrors RC-1's keep
# list; read-only.
validate_repos_at_rest() {
  say 'validate repos at rest (fail-closed)'
  local id left bad=0
  left=$(dnf5 repolist --enabled 2>/dev/null | awk 'NR > 1 {print $1}') || die 'repo rest-state query failed'
  for id in ${left}; do
    case "${id}" in
      fedora | updates | updates-archive | fedora-cisco-openh264) ;;
      *)
        echo "REPO-LEAK: ${id} enabled at rest" >&2
        bad=1
        ;;
    esac
  done
  if ((bad != 0)); then die 'third-party repos enabled at rest (see REPO-LEAK lines)'; fi
  say "repos at rest: $(echo "${left}" | tr '\n' ' ')"
}

# install_priority [--official-repo=ID] PKG... — one Name per transaction so a
# Terra-only and a Fusion-only Name in one call cannot fail each other.
install_priority() {
  local official=() pkg
  while [[ ${1-} == --official-repo=* ]]; do
    official+=(--enablerepo="${1#--official-repo=}")
    shift
  done
  local attempt
  for pkg in "$@"; do
    if have_rpm "${pkg}"; then continue; fi
    attempt=0
    while ! _ladder_once "${pkg}" "${official[@]}"; do
      attempt=$((attempt + 1))
      if ((attempt >= 3)); then
        echo "No NEVRA for ${pkg} in vendor/Terra/Fusion/Fedora (3 passes)" >&2
        # Final attempt with no skip flags: those can skip an installable
        # package outright. A success here installs it; a failure lands the
        # true solver error in the log (no --assumeno ambiguity).
        echo "--- final no-skip attempt for ${pkg} ---" >&2
        if _ladder_once "${pkg}" --no-skip "${official[@]}"; then return 0; fi
        tail -n 40 /tmp/compose-last.log >&2 || true
        return 1
      fi
      echo "pkg: ${pkg}: ladder pass ${attempt} missed, cleaning metadata and retrying" >&2
      dnf5 clean metadata >/dev/null 2>&1 || true
      sleep 20
    done
  done
}

# One full ladder pass for a single Name. Extra args are --enablerepo flags
# for the vendor rung (possibly none); a leading --no-skip drops the
# --skip-broken/--skip-unavailable flags (those can mask or break solves:
# build 33888294144 showed a package matching in fusion metadata yet skipped
# on every skip-flag rung). Returns 0 with the RPM installed.
_ladder_once() {
  local pkg=$1
  shift
  local -a skip=(--skip-broken --skip-unavailable)
  if [[ ${1-} == --no-skip ]]; then skip=(); shift; fi
  if (($#)) && _q dnf5 -y install "${skip[@]}" "$@" "${pkg}" && have_rpm "${pkg}"; then echo "pkg: ${pkg} (vendor)"; return 0; fi
  if _q dnf5 -y install "${skip[@]}" "${TERRA_REPOS[@]/#/--enablerepo=}" "${pkg}" && have_rpm "${pkg}"; then echo "pkg: ${pkg} (terra)"; return 0; fi
  if _q dnf5 -y install "${skip[@]}" "${FUSION_REPOS[@]/#/--enablerepo=}" "${pkg}" && have_rpm "${pkg}"; then echo "pkg: ${pkg} (fusion)"; return 0; fi
  if _q dnf5 -y install "${pkg}" && have_rpm "${pkg}"; then echo "pkg: ${pkg} (fedora)"; return 0; fi
  return 1
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

# Steam is inherently multilib (x86_64 plus x86-32 pipewire). The ublue base
# ships an epoch-1 libfdk-aac fossil (gone from all current repos) that
# obsoletes every epoch-0 i686 fdk-aac, breaking the 32-bit pipewire chain
# steam needs (proven by the assumeno probes in build 33884584709; and
# obsoletes=0 does NOT lift solver obsoletes-conflicts, tried in e9bf1a8).
# Fedora's fdk-aac-free provides the same libfdk-aac.so.2 soname with no
# obsoletes and no by-name requirers, so swap the fossil away, seed the i686
# multilib pair, then run the normal ladder.
install_steam() {
  say 'steam (fossil swap + multilib seed + ladder)'
  if have_rpm libfdk-aac; then
    dnf5 -y swap libfdk-aac fdk-aac-free >/tmp/compose-last.log 2>&1 ||
      { tail -n 30 /tmp/compose-last.log >&2 || true; die 'steam seed: libfdk-aac -> fdk-aac-free swap failed'; }
  fi
  dnf5 -y install fdk-aac-free.i686 >/tmp/compose-last.log 2>&1 ||
    { tail -n 30 /tmp/compose-last.log >&2 || true; die 'steam seed: fdk-aac-free.i686 failed'; }
  install_priority steam
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


# Vendor .repo from URL (overwrite), install argv, disable every repo file
# the addrepo created, then verify fail-closed. New files are found by
# snapshot diff, not by glob alone: a quoted glob never expands (the
# hardware_razer leak in build 33954254004 — disable ran on a literal
# asterisk path and skipped). The glob stays as belt-and-braces, UNQUOTED.
vendor_repo_install() {
  local glob=$1 url=$2
  shift 2
  local rc=0 was_off=0 f b
  local -a before=() after=() new=()
  shopt -q nullglob || was_off=1
  shopt -s nullglob
  before=(/etc/yum.repos.d/*.repo)
  dnf5 -y config-manager addrepo --overwrite --from-repofile="${url}" >/tmp/compose-last.log 2>&1 || rc=$?
  if ((rc == 0)); then _q dnf5 -y install "$@" || rc=$?; fi
  # Intentionally unquoted: /etc/yum.repos.d/${glob} must expand (see above).
  after=(/etc/yum.repos.d/*.repo /etc/yum.repos.d/${glob})
  if ((was_off)); then shopt -u nullglob; fi
  for f in "${after[@]}"; do
    for b in "${before[@]}"; do [[ ${f} == "${b}" ]] && continue 2; done
    new+=("${f}")
  done
  if ((${#new[@]})); then
    disable_yum_repos "${new[@]}"
    for f in "${new[@]}"; do
      [[ -f ${f} ]] || continue
      if grep -qE '^[[:space:]]*enabled[[:space:]]*=[[:space:]]*1([^0-9]|$)' "${f}"; then
        die "vendor repo still enabled after install: ${f}"
      fi
    done
  fi
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
# setpriv, not runuser: runuser opens a PAM session, and pam_limits applies
# /etc/security/limits.d (our rtprio/nice/memlock grants) via setrlimit —
# inside the podman build container the hard limits cannot be raised, the
# session open fails (PAM_PERM_DENIED) and every kmod build dies. setpriv
# performs the identical uid/gid/groups switch with no PAM involvement.
fix_akmods_ostree_post() {
  local ostree_post=/usr/sbin/akmods-ostree-post
  [[ -f ${ostree_post} ]] || return 0
  if grep -q 'setpriv' "${ostree_post}"; then return 0; fi
  if ! sed -E -i '0,/^([[:space:]]*)akmodsbuild /s||\1chown akmods "${tmpdir}" "${tmpdir}results" \&\& unset TMPDIR \&\& CC=clang LD=ld.lld LLVM=1 KCFLAGS="-fno-lto -fno-split-lto-unit" MAKEFLAGS="-j$(nproc)" /usr/bin/setpriv --reuid=akmods --regid=akmods --init-groups /usr/bin/akmodsbuild |' "${ostree_post}"; then
    die "failed to patch ${ostree_post}"
  fi
  grep -q '/usr/bin/setpriv' "${ostree_post}" || die "akmods-ostree-post patch did not apply"
  bash -n "${ostree_post}" || die "patched ${ostree_post} failed syntax check"
}

# CachyOS kernel set from COPR over the Fedora set. Base set is fatal;
# modules-extra and unmatched devel are best-effort.
# Isolated COPR: materialize the .repo file, then never enable it — every
# install addresses it explicitly via --enablerepo so no other transaction
# can resolve foreign deps from it.
_install_cachyos_once() {
  local repo_id="copr:copr.fedorainfracloud.org:${CACHYOS_COPR//\//:}"
  dnf5 -y copr enable "${CACHYOS_COPR}" >/dev/null 2>&1 || return 1
  dnf5 -y copr disable "${CACHYOS_COPR}" >/dev/null 2>&1 || true
  dnf5 -y install --enablerepo="${repo_id}" \
    kernel-cachyos-lto kernel-cachyos-lto-devel-matched >/tmp/compose-last.log 2>&1 || return 1
  dnf5 -y install --enablerepo="${repo_id}" \
    kernel-cachyos-lto-modules-extra >/dev/null 2>&1 ||
    echo 'kernel-cachyos-lto-modules-extra unavailable; continuing' >&2
  dnf5 -y install --enablerepo="${repo_id}" \
    kernel-cachyos-lto-devel >/dev/null 2>&1 ||
    echo 'kernel-cachyos-lto-devel unavailable; continuing' >&2
  return 0
}

install_cachyos_kernel() {
  retry 6 cachyos-kernel _install_cachyos_once || die 'CachyOS kernel install failed'
}

# Build a kmod via the patched scriptlet (the akmods client cannot carry the
# LLVM/KCFLAGS env). $1 akmod name, $2 find pattern, $3 kver, $4 SRPM glob.
build_kmod() {
  mkdir -p /run/akmods
  chown root:akmods /run/akmods
  chmod 0770 /run/akmods
  if ! find "/usr/lib/modules/$3" -path "*$2" -print -quit 2>/dev/null | grep -q .; then
    local srpm
    srpm=$(ls /usr/src/akmods/$4 2>/dev/null | LC_ALL=C sort -V | tail -n1 || true)
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
  # Re-entrant (post-upgrade re-assert): the first call leaves /usr/local as
  # a symlink to /var/usrlocal, which cp cannot merge a directory into.
  # Materialize it; the dance below re-merges and re-links.
  if [[ -L /usr/local ]]; then rm /usr/local; mkdir -p /usr/local; fi
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
    if have_rpm "${pkg}"; then
      rpm --erase "${pkg}" --nodeps >>/tmp/compose-last.log 2>&1 ||
        { tail -n 12 /tmp/compose-last.log >&2; die "erase ${pkg} failed"; }
    fi
  done
  rm -rf /usr/lib/modules/*
  install_cachyos_kernel
  rpm -q kernel-cachyos-lto-core >/dev/null || die 'kernel-cachyos-lto-core missing after COPR install'
  KVER=$(rpm -q kernel-cachyos-lto-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | LC_ALL=C sort -V | tail -n1 || true)
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
  retry 6 nvidia dnf5 -y install "${TERRA_NVIDIA_REPOS[@]/#/--enablerepo=}" --disablerepo=fedora-multimedia \
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
  dnf5 -y install "${FUSION_REPOS[@]/#/--enablerepo=}" libva-nvidia-driver.x86_64 libva-nvidia-driver.i686 >/tmp/compose-last.log 2>&1 ||
    die 'libva-nvidia-driver failed'
  install_priority vulkan-loader.x86_64 vulkan-loader.i686 vulkan-tools
}

# Pi coding agent (pi.dev): always latest, fetched host-side into the build
# context by ci/fetch-pi.sh as a staged npm tree (pure JS, installed with
# --ignore-scripts upstream, so the tree is relocatable). Extracted into
# /usr here; runs on the nodejs+npm every image already installs. Ships the
# `pi` TUI/print-mode agent plus the /etc/skel/.pi scaffolding (global
# AGENTS.md + quickshell-bar skill) from the system_files overlay.
install_pi() {
  say 'pi coding agent (latest, host-fetched)'
  local tarball
  tarball=$(find /ctx/_build/pi -name 'pi-*.tar.gz' -print -quit 2>/dev/null || true)
  [[ -n ${tarball} ]] || die 'Pi tarball missing under /ctx/_build/pi'
  # Pi requires node >= 22.19 (its engines field; fs.globSync). Every image
  # installs nodejs just above this call; re-assert a modern stack so a repo
  # reshuffle can never ship a pi that dies at startup, then let the
  # --version gate below be the final arbiter.
  if ! node -e 'const [a, b] = process.versions.node.split(".").map(Number); process.exit(a > 22 || (a === 22 && b >= 19) ? 0 : 1)' 2>/dev/null; then
    install_any nodejs24-npm nodejs22-npm || die 'no nodejs >= 22.19 available for pi'
  fi
  tar -C /usr -xzpf "${tarball}"
  [[ -x /usr/bin/pi ]] || die 'pi binary missing after extract'
  PI_OFFLINE=1 /usr/bin/pi --version >/dev/null 2>&1 || die 'pi --version failed in build root'
  echo "pi: $(basename "${tarball}" .tar.gz)"
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

# yt-dlp: latest stable release binary from upstream (outside Terra, whose
# -git/-ejs packages proved flaky). Standalone binary, no python deps;
# gated on the binary executing.
install_ytdlp_latest() {
  say 'yt-dlp (latest stable binary)'
  local api tag url dest=/usr/local/bin/yt-dlp
  api=$(_github_api_get https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest) || die 'yt-dlp latest lookup failed'
  url=$(echo "${api}" | jq -r '.assets[] | select(.name == "yt-dlp") | .browser_download_url' | head -n1 || true)
  [[ -n ${url} && ${url} != null ]] || die 'yt-dlp binary asset missing in latest release'
  tag=$(echo "${api}" | jq -r '.tag_name' || true)
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "${dest}" "${url}" || die 'yt-dlp download failed'
  chmod 0755 "${dest}"
  "${dest}" --version >/dev/null || die 'yt-dlp binary does not execute'
  echo "yt-dlp: ${tag}"
}


# ---- First-party dev toolchain (official upstreams; never Terra) ----
# Bun (same payload as https://bun.sh/install), opencode CLI + Desktop
# (official anomalyco/opencode releases), system rustup stable,
# uv/uvx, mise, starship. All resolve "latest" at build time via the
# GitHub releases API and fail closed (die) when the asset is missing.
# python3 parses the API (jq may not be installed yet at this stage);
# python3 tarfile/zipfile extract (tar may not be installed yet either).
# _github_api_get <url>: curl a GitHub API URL with patience. The API
# intermittently 403s/5xxes single requests (build 33896110049 died on one
# such blip at the starship lookup after every sibling lookup succeeded),
# and curl's --retry fires all attempts inside the same blip window. Retry
# with exponential backoff and always report the HTTP status so the next
# failure is attributable on sight. Prints the body on success.
# _GITHUB_API_RETRIES/_GITHUB_API_DELAY override the default 5 tries / 10s
# base delay (used by tests to keep failure-path checks fast).
_github_api_get() { # <url> -> body on stdout
  # Ephemeral workflow token via BuildKit secret mount (never the owner PAT,
  # never logged — only HTTP codes reach the log): raises the API budget when
  # present, anonymous with backoff otherwise.
  local url="$1" body code attempt=1 delay="${_GITHUB_API_DELAY:-10}" max="${_GITHUB_API_RETRIES:-5}"
  local -a auth=()
  if [[ -s /run/secrets/GITHUB_TOKEN ]]; then
    auth=(-H "Authorization: Bearer $(cat /run/secrets/GITHUB_TOKEN)")
  fi
  body="$(mktemp)" || return 1
  while true; do
    code="$(curl -sS --proto '=https' --max-time 90 "${auth[@]}" -o "${body}" -w '%{http_code}' \
      "${url}" 2>/dev/null)" || code=000
    if [[ ${code} == 200 ]]; then
      cat "${body}"; rm -f "${body}"; return 0
    fi
    echo "WARN: GitHub API ${url} -> HTTP ${code} (attempt ${attempt}/${max})" >&2
    if [[ ${attempt} -ge ${max} ]]; then rm -f "${body}"; return 1; fi
    sleep "${delay}"
    attempt=$((attempt + 1)); delay=$((delay * 2))
  done
}

_github_latest_asset_url() { # <owner/repo> <asset-name-regex> -> "tag|url"
  local repo="$1" pattern="$2" out api attempt=1
  while true; do
    api="$(_github_api_get "https://api.github.com/repos/${repo}/releases?per_page=5")" || return 1
    out="$(printf '%s' "${api}" | python3 -c '
import json,sys,re
pat = re.compile(sys.argv[1])
try:
    rels = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for r in rels:
    if r.get("draft") or r.get("prerelease"):
        continue
    for a in r.get("assets", []):
        n = a.get("name", "")
        if pat.search(n) and not n.endswith(".sha256"):
            print(str(r.get("tag_name", "")) + "|" + a.get("browser_download_url", ""))
            sys.exit(0)
sys.exit(1)
' "${pattern}")" && [[ -n "${out}" ]] && { printf '%s\n' "${out}"; return 0; }
    # HTTP 200 but unparseable or asset genuinely absent: one immediate
    # retry (cheap insurance against a truncated-JSON blip), then fail.
    echo "WARN: ${repo}: HTTP 200 but no asset matching ${pattern} (attempt ${attempt}/2)" >&2
    if [[ ${attempt} -ge 2 ]]; then return 1; fi
    attempt=$((attempt + 1))
  done
}

_extract_github_asset() { # <archive> <destdir>
  python3 -c '
import sys,zipfile,tarfile
src, dst = sys.argv[1], sys.argv[2]
if zipfile.is_zipfile(src):
    zipfile.ZipFile(src).extractall(dst)
elif tarfile.is_tarfile(src):
    tarfile.open(src).extractall(dst)
else:
    sys.exit("not an archive: " + src)
' "$1" "$2"
}

# with_tmp_home <cmd...>: run a first-run binary check with a fresh writable
# HOME. Proven hazard: opencode (Bun runtime) does mkdir "$HOME" on startup
# and exits nonzero when the compose-time HOME is not writable. Stdout of a
# successful run passes through; a failure prints the tail, then nonzero.
with_tmp_home() {
  local tmp_home rc=0
  tmp_home="$(mktemp -d)" || return 1
  HOME="${tmp_home}" "$@" >/tmp/compose-last.log 2>&1 || rc=$?
  rm -rf "${tmp_home}"
  if [[ ${rc} -ne 0 ]]; then
    tail -n 15 /tmp/compose-last.log >&2 || true
    return 1
  fi
  cat /tmp/compose-last.log
}

_stage_install_bin() { # <stagedir> <bin-name> [bin-name...]
  local stage="$1" b src
  shift
  for b in "$@"; do
    src="$(find "${stage}" -type f -name "${b}" 2>/dev/null | head -n 1 || true)"
    if [[ -z "${src}" ]]; then
      echo "COMPOSE-FAIL: binary '${b}' not found in downloaded asset" >&2
      return 1
    fi
    install -m755 "${src}" "/usr/local/bin/${b}"
  done
}

install_bun_official() {
  say 'bun (official oven-sh/bun release)'
  say "toolchain env: HOME=${HOME:-<unset>} UID=$(id -u)"
  local info tag url tmp stage ver
  info="$(_github_latest_asset_url 'oven-sh/bun' '^bun-linux-(x64|x86_64)\.zip$')" ||
    die 'bun: no matching linux x86_64 release asset'
  tag="${info%%|*}"; url="${info#*|}"
  say "bun ${tag}"
  tmp="$(mktemp -d)"; stage="${tmp}/stage"; mkdir -p "${stage}"
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors --max-time 600 \
    -o "${tmp}/asset" "${url}" || die 'bun: download failed'
  _extract_github_asset "${tmp}/asset" "${stage}" || die 'bun: extract failed'
  _stage_install_bin "${stage}" bun || die 'bun: binary not found in asset'
  rm -rf "${tmp}"
  ver="$(with_tmp_home bun --version)" || die 'bun: installed binary does not run'
  say "bun ${ver}"
}

install_opencode_official() {
  say 'opencode CLI + Desktop (official anomalyco/opencode releases)'
  local info tag url tmp stage pkg ver
  info="$(_github_latest_asset_url 'anomalyco/opencode' '^opencode-linux-x64\.tar\.gz$')" ||
    die 'opencode CLI: no matching linux x86_64 release asset'
  tag="${info%%|*}"; url="${info#*|}"
  say "opencode CLI ${tag}"
  tmp="$(mktemp -d)"; stage="${tmp}/stage"; mkdir -p "${stage}"
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors --max-time 600 \
    -o "${tmp}/asset" "${url}" || die 'opencode CLI: download failed'
  _extract_github_asset "${tmp}/asset" "${stage}" || die 'opencode CLI: extract failed'
  _stage_install_bin "${stage}" opencode || die 'opencode CLI: binary not found in asset'
  ver="$(with_tmp_home opencode --version)" || die 'opencode CLI: installed binary does not run'
  say "opencode CLI ${ver}"
  info="$(_github_latest_asset_url 'anomalyco/opencode' '^opencode-desktop-linux-x86_64\.rpm$')" ||
    die 'opencode Desktop: no matching linux x86_64 RPM asset'
  tag="${info%%|*}"; url="${info#*|}"
  say "opencode Desktop ${tag}"
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors --max-time 600 \
    -o "${tmp}/desktop.rpm" "${url}" || die 'opencode Desktop: download failed'
  pkg="$(rpm -qp --queryformat '%{NAME}' "${tmp}/desktop.rpm" 2>/dev/null || true)"
  [[ -n "${pkg}" ]] || die 'opencode Desktop: RPM has no package name'
  dnf5 -y install "${tmp}/desktop.rpm" >/tmp/compose-last.log 2>&1 ||
    { tail -n 40 /tmp/compose-last.log >&2 || true; die 'opencode Desktop RPM install failed'; }
  rm -rf "${tmp}"
  rpm -q "${pkg}" >/dev/null 2>&1 || die 'opencode Desktop: package not installed'
  if [[ -z "$(rpm -ql "${pkg}" 2>/dev/null | grep '\.desktop$' | head -n 1 || true)" ]]; then
    die 'opencode Desktop: no .desktop entry shipped'
  fi
  say "opencode Desktop ${pkg} installed"
}

install_rustup_system() {
  say 'rustup + stable toolchain (official sh.rustup.rs, system-wide)'
  export RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
  mkdir -p "${RUSTUP_HOME}" "${CARGO_HOME}"
  curl --proto '=https' --tlsv1.2 -sSf --retry 3 --retry-all-errors --max-time 120 \
    https://sh.rustup.rs -o /tmp/rustup-init.sh || die 'rustup: init script download failed'
  sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
    --default-toolchain stable >/tmp/compose-last.log 2>&1 ||
    { tail -n 30 /tmp/compose-last.log >&2 || true; die 'rustup: toolchain install failed'; }
  rm -f /tmp/rustup-init.sh
  local t cargo_ver rustc_ver
  for t in rustup cargo rustc rustdoc clippy-driver rustfmt cargo-clippy cargo-fmt; do
    if [[ -x "${CARGO_HOME}/bin/${t}" ]]; then
      ln -sfn "${CARGO_HOME}/bin/${t}" "/usr/local/bin/${t}"
    fi
  done
  mkdir -p /etc/profile.d
  cat >/etc/profile.d/rust.sh <<'EOF'
# Ryven: system rustup (RUSTUP_HOME=/opt/rustup, CARGO_HOME=/opt/cargo).
export RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
case ":${PATH:-}:" in
  *:/opt/cargo/bin:*|*:/usr/local/bin:*) ;;
  *) export PATH="/opt/cargo/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}" ;;
esac
EOF
  export PATH="/opt/cargo/bin:/usr/local/bin:${PATH}"
  cargo_ver="$(with_tmp_home cargo --version)" || die 'rustup: cargo does not run'
  rustc_ver="$(with_tmp_home rustc --version)" || die 'rustup: rustc does not run'
  say "rustup ${cargo_ver} / ${rustc_ver}"
}

install_uv_official() {
  say 'uv/uvx (official astral-sh/uv release)'
  local info tag url tmp stage ver
  info="$(_github_latest_asset_url 'astral-sh/uv' '^uv-x86_64-unknown-linux-gnu\.tar\.gz$')" ||
    die 'uv: no matching linux x86_64 release asset'
  tag="${info%%|*}"; url="${info#*|}"
  say "uv ${tag}"
  tmp="$(mktemp -d)"; stage="${tmp}/stage"; mkdir -p "${stage}"
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors --max-time 300 \
    -o "${tmp}/asset" "${url}" || die 'uv: download failed'
  _extract_github_asset "${tmp}/asset" "${stage}" || die 'uv: extract failed'
  _stage_install_bin "${stage}" uv uvx || die 'uv: binaries not found in asset'
  rm -rf "${tmp}"
  ver="$(with_tmp_home uv --version)" || die 'uv: installed binary does not run'
  say "uv ${ver}"
}

install_mise_official() {
  say 'mise (official jdx/mise release)'
  local info tag url tmp ver
  info="$(_github_latest_asset_url 'jdx/mise' '^mise-v.*-linux-x64$')" ||
    die 'mise: no matching linux x64 release asset'
  tag="${info%%|*}"; url="${info#*|}"
  say "mise ${tag}"
  tmp="$(mktemp -d)"
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors --max-time 600 \
    -o "${tmp}/mise" "${url}" || die 'mise: download failed'
  install -m755 "${tmp}/mise" /usr/local/bin/mise
  rm -rf "${tmp}"
  ver="$(with_tmp_home mise --version)" || die 'mise: installed binary does not run'
  say "mise ${ver}"
}

install_starship_official() {
  say 'starship (official starship/starship release)'
  local info tag url tmp stage ver
  info="$(_github_latest_asset_url 'starship/starship' '^starship-x86_64-unknown-linux-gnu\.tar\.gz$')" ||
    die 'starship: no matching linux x86_64 release asset'
  tag="${info%%|*}"; url="${info#*|}"
  say "starship ${tag}"
  tmp="$(mktemp -d)"; stage="${tmp}/stage"; mkdir -p "${stage}"
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors --max-time 300 \
    -o "${tmp}/asset" "${url}" || die 'starship: download failed'
  _extract_github_asset "${tmp}/asset" "${stage}" || die 'starship: extract failed'
  _stage_install_bin "${stage}" starship || die 'starship: binary not found in asset'
  rm -rf "${tmp}"
  ver="$(with_tmp_home starship --version)" || die 'starship: installed binary does not run'
  cat >/etc/starship.toml <<'EOF'
# Ryven default prompt: compact, shows our toolchain (node/rust/python).
format = "$directory$git_branch$git_status$nodejs$rust$python$sudo$jobs$cmd_duration$line_break$character"
[directory]
truncation_length = 3
truncate_to_repo = true
[character]
success_symbol = "[➜](bold green)"
error_symbol = "[➜](bold red)"
[cmd_duration]
min_time = 2000
EOF
  mkdir -p /etc/profile.d /etc/skel
  cat >/etc/profile.d/starship.sh <<'EOF'
# Ryven: starship prompt (first-party binary in /usr/local/bin).
if command -v starship >/dev/null 2>&1; then
  export STARSHIP_CONFIG="${STARSHIP_CONFIG:-/etc/starship.toml}"
  if [[ -n "${BASH_VERSION:-}" ]]; then
    eval "$(starship init bash)"
  elif [[ -n "${ZSH_VERSION:-}" ]]; then
    eval "$(starship init zsh)"
  fi
fi
EOF
  touch /etc/skel/.bashrc
  if ! grep -q 'starship init bash' /etc/skel/.bashrc 2>/dev/null; then
    cat >>/etc/skel/.bashrc <<'EOF'

# Ryven: starship prompt.
if command -v starship >/dev/null 2>&1; then
  export STARSHIP_CONFIG="${STARSHIP_CONFIG:-/etc/starship.toml}"
  eval "$(starship init bash)"
fi
EOF
  fi
  say "starship ${ver}"
}


# proton-cachyos: latest GitHub release asset (floats; HTTPS-only integrity,
# upstream publishes per-asset hashes inconsistently — vdf gate stays).
install_proton_latest() {
  say 'proton-cachyos (latest release)'
  local api tag url dest=/usr/share/steam/compatibilitytools.d
  api=$(_github_api_get https://api.github.com/repos/CachyOS/proton-cachyos/releases/latest) || die 'proton latest lookup failed'
  url=$(echo "${api}" | jq -r '.assets[] | select(.name | test("x86_64\\.tar\\.(xz|zst)$")) | .browser_download_url' | head -n1 || true)
  [[ -n ${url} && ${url} != null ]] || die 'proton x86_64 asset missing in latest release'
  tag=$(echo "${api}" | jq -r '.tag_name' || true)
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
    grep -oE 'v[0-9][0-9A-Za-z._-]*' | LC_ALL=C sort -V | tail -n1 || true)
  if [[ -z ${tag} ]]; then
    tag=$(git ls-remote --symref "https://github.com/${repo}" HEAD 2>/dev/null |
      grep -oE 'refs/heads/[^[:space:]]+' | head -n1 || true)
    [[ -n ${tag} ]] || die "cannot resolve latest ref for ${repo}"
    echo "branch:${tag#refs/heads/}"
  else
    echo "tag:${tag}"
  fi
}

# oo7 Secret Service stack, cargo-built at the latest tag (Fedora ships only
# oo7-cli; daemon/portal/PAM power the keyring on every image).
install_oo7() {
  if command -v oo7-daemon >/dev/null 2>&1 && [[ -e /usr/lib/security/pam_oo7.so ]]; then return 0; fi
  say 'oo7 (latest tag, cargo)'
  local ref kind
  ref=$(github_latest_tag linux-credentials/oo7)
  kind=${ref%%:*} ref=${ref#*:}
  echo "oo7: ${kind} ${ref}"
  if ! command -v cargo >/dev/null 2>&1; then
    dnf5 -y install rust cargo >/tmp/compose-last.log 2>&1 ||
      die 'oo7 toolchain failed'
  fi
  dnf5 -y install git gcc pkgconf-pkg-config >/tmp/compose-last.log 2>&1 || die 'oo7 toolchain failed'
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
UseIn=hyprland,sway,kde
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
  # System rustup (installed earlier in every image) already provides cargo;
  # only pull Fedora's toolchain when no cargo is on PATH (saves a full
  # install+remove cycle).
  if ! command -v cargo >/dev/null 2>&1; then
    dnf5 -y install rust cargo >/tmp/compose-last.log 2>&1 ||
      die 'wl-clip-persist toolchain failed'
  fi
  dnf5 -y install gcc wayland-devel libxkbcommon-devel pkgconf-pkg-config >/tmp/compose-last.log 2>&1 ||
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
  # Vendor census (best-effort observability, never fatal): which repos fed
  # this upgrade, and did any kernel/mesa payload come from outside Fedora?
  echo '--- upgrade vendor census (repo: count) ---' >&2
  awk '/^(Upgrading|Installing|Downgrading):/{sec=1; next} /^(Removing|Obsoleting|Upgraded|Installed):/{sec=0; next} /^$/{sec=0} sec && NF>=4 && $2 ~ /^(x86_64|i686|noarch|aarch64)$/ && $4 !~ /^@@/ {print $4}' /tmp/upgrade.log 2>/dev/null |
    LC_ALL=C sort | LC_ALL=C uniq -c | LC_ALL=C sort -rn >&2 || true
  echo '--- non-Fedora kernel/mesa in this upgrade ---' >&2
  awk '/^(Upgrading|Installing|Downgrading):/{sec=1; next} /^(Removing|Obsoleting|Upgraded|Installed):/{sec=0; next} /^$/{sec=0} sec && NF>=4 && $2 ~ /^(x86_64|i686|noarch|aarch64)$/ && $1 ~ /^(kernel|mesa|libdrm|egl|vulkan|xorg-x11-drv)/ && $4 !~ /^(fedora|updates|updates-archive|fedora-cisco-openh264)$/ && $4 !~ /^@@/ {print}' /tmp/upgrade.log 2>/dev/null >&2 || true
  [[ ${rc} == 0 ]] || die "refresh upgrade failed (rc=${rc})"
}


# ---- Browsers (always latest, upstream-fetched) ----
# Firefox + Zen install from their official upstream release payloads that
# ci/fetch-browsers.sh drops into the build context (betterbird pattern,
# SHA512-verified for Firefox at fetch time). Brave Origin installs from the
# official RPM published on brave/brave-browser GitHub releases (sha256
# verified at fetch time) plus the tiny brave-keyring package it Requires,
# fetched from Brave's official repo repodata. All three update on the
# weekly image rebuild; no vendor repo stays enabled at rest (RC-1).
install_firefox() {
  say 'firefox (latest stable, host-fetched)'
  local tarball ver s
  tarball=$(find /ctx/_build/firefox -name 'firefox-*.tar.xz' -print -quit 2>/dev/null || true)
  [[ -n ${tarball} ]] || die 'firefox tarball missing under /ctx/_build/firefox'
  ver=$(basename "${tarball}" .tar.xz) # firefox-<version>
  # Runtime libs the Mozilla tarball links against but does not bundle.
  install_priority gtk3 libXt dbus-glib alsa-lib
  rm -rf /opt/firefox /opt/firefox-*
  tar -xJf "${tarball}" -C /opt || die 'firefox: extract failed'
  [[ -d /opt/firefox ]] || die 'firefox: unexpected tarball layout (no /opt/firefox)'
  mv /opt/firefox "/opt/${ver}"
  ln -sfn "/opt/${ver}" /opt/firefox
  mkdir -p /usr/local/bin
  ln -sfn "/opt/${ver}/firefox" /usr/local/bin/firefox
  for s in 16 32 48 64 128; do
    if [[ -f "/opt/${ver}/browser/chrome/icons/default/default${s}.png" ]]; then
      install -D -m 0644 "/opt/${ver}/browser/chrome/icons/default/default${s}.png" \
        "/usr/share/icons/hicolor/${s}x${s}/apps/firefox.png"
    fi
  done
  [[ -x "/opt/${ver}/firefox" ]] || die "firefox ${ver}: binary missing after install"
  echo "firefox: ${ver#firefox-}"
}

install_zen() {
  say 'zen browser (latest stable, host-fetched)'
  local tarball ver s
  tarball=$(find /ctx/_build/zen -name 'zen-*.tar.xz' -print -quit 2>/dev/null || true)
  [[ -n ${tarball} ]] || die 'zen tarball missing under /ctx/_build/zen'
  ver=$(basename "${tarball}" .tar.xz) # zen-<tag>
  # Same Gecko runtime deps as Firefox (shared install above may have run
  # already; install_priority is a no-op for installed packages).
  install_priority gtk3 libXt dbus-glib alsa-lib
  rm -rf /opt/zen /opt/zen-*
  tar -xJf "${tarball}" -C /opt || die 'zen: extract failed'
  [[ -d /opt/zen ]] || die 'zen: unexpected tarball layout (no /opt/zen)'
  mv /opt/zen "/opt/${ver}"
  ln -sfn "/opt/${ver}" /opt/zen
  mkdir -p /usr/local/bin
  ln -sfn "/opt/${ver}/zen" /usr/local/bin/zen
  for s in 16 32 48 64 128; do
    if [[ -f "/opt/${ver}/browser/chrome/icons/default/default${s}.png" ]]; then
      install -D -m 0644 "/opt/${ver}/browser/chrome/icons/default/default${s}.png" \
        "/usr/share/icons/hicolor/${s}x${s}/apps/zen-browser.png"
    fi
  done
  [[ -x "/opt/${ver}/zen" ]] || die "zen ${ver}: binary missing after install"
  echo "zen: ${ver#zen-}"
}

install_brave_origin() {
  say 'brave-origin (latest GitHub release RPM, sha256-verified)'
  local ver keyring pkg
  keyring=$(find /ctx/_build/brave -name 'brave-keyring-*.noarch.rpm' -print -quit 2>/dev/null || true)
  pkg=$(find /ctx/_build/brave -name 'brave-origin-*.x86_64.rpm' -print -quit 2>/dev/null || true)
  [[ -n ${keyring} ]] || die 'brave-keyring RPM missing under /ctx/_build/brave'
  [[ -n ${pkg} ]] || die 'brave-origin RPM missing under /ctx/_build/brave'
  # Both from local files; remaining deps resolve from the enabled Fedora
  # repos. rpm paths are quoted so the preflight tokenizer skips them.
  dnf5 -y install "${keyring}" "${pkg}" >/tmp/compose-last.log 2>&1 ||
    { tail -n 40 /tmp/compose-last.log >&2 || true; die 'brave-origin RPM install failed'; }
  have_rpm brave-origin || die 'brave-origin missing after install'
  [[ -x /opt/brave.com/brave-origin/brave-origin ]] || die 'brave-origin: binary missing after install'
  # The RPM ships a cron.daily stub that re-adds Brave's yum repo on classic
  # hosts: pointless (no crond here) and unwanted on ostree. Drop it.
  rm -f /etc/cron.daily/brave-origin
  ver=$(rpm -q --qf '%{VERSION}' brave-origin)
  echo "brave-origin: ${ver}"
}

# Ryven enterprise policies for the Gecko browsers (Firefox + Zen): the full
# policy set ships at /usr/share/ryven/gecko-policies.json (system_files
# overlay) and is copied into each browser's distribution/ directory, where
# Gecko reads it at first run. Its ExtensionSettings preinstall the managed
# extension stack from AMO "latest" URLs (uBlock Origin, Violentmonkey,
# Bitwarden, KeePassXC-Browser, Facebook Container, Cookie AutoDelete,
# Consent-O-Matic, ...) and ExtensionUpdate keeps them current.
# normal_installed = present OOTB, user-removable, never admin-locked.
# Fail-closed: invalid JSON or a missing browser kills the build.
install_gecko_policies() {
  local src=/usr/share/ryven/gecko-policies.json dir
  [[ -s ${src} ]] || die "gecko policies: ${src} missing (overlay not applied?)"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${src}" ||
    die 'gecko policies: invalid JSON'
  [[ -x /opt/firefox/firefox ]] || die 'gecko policies: firefox missing at /opt/firefox'
  [[ -x /opt/zen/zen ]] || die 'gecko policies: zen missing at /opt/zen'
  for dir in /opt/firefox /opt/zen; do
    mkdir -p "${dir}/distribution"
    install -m 0644 "${src}" "${dir}/distribution/policies.json"
    say "gecko policies installed for ${dir}"
  done
}
