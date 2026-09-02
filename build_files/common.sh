#!/bin/bash
# Shared compose helpers for Ryven and Ryven-WL. Sourced, not executed.
# Callers must already have set -ouex pipefail or inherit it here.

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

# wl-clip-persist is not in Fedora/Terra/Fusion (2026-09). RPM first, then
# cargo --locked from the upstream tag into /usr/bin. Not curl|sh.
install_wl_clip_persist() {
  if command -v wl-clip-persist >/dev/null 2>&1; then
    return 0
  fi
  if install_priority wl-clip-persist; then
    return 0
  fi
  dnf5 -y install rust cargo gcc git wayland-devel libxkbcommon-devel pkgconf-pkg-config
  mkdir -p /tmp/wl-clip-persist
  git clone --depth 1 --branch v0.5.0 \
    https://github.com/Linus789/wl-clip-persist.git /tmp/wl-clip-persist
  (
    cd /tmp/wl-clip-persist
    CARGO_HOME=/tmp/cargo cargo build --release --locked
  )
  install -D -m 0755 /tmp/wl-clip-persist/target/release/wl-clip-persist \
    /usr/bin/wl-clip-persist
  rm -rf /tmp/wl-clip-persist /tmp/cargo
  command -v wl-clip-persist >/dev/null || die 'wl-clip-persist build produced no binary'
}
