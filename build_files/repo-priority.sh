#!/bin/bash
# Package source priority (highest first):
#   1. Official vendor/dev repos already on disk (Brave, mise, OpenRazer, …)
#   2. Terra f44 (terra, terra-multimedia, terra-mesa)
#   3. RPM Fusion free/nonfree (+ updates)
#   4. Fedora
#
# Names must match a real NEVRA. Terra Names were checked against
# terrapkg/packages branch f44. Subpackages (openrazer-daemon) are valid
# even when the spec Name: is the parent.

TERRA_REPOS="terra,terra-multimedia,terra-mesa"
FUSION_REPOS="rpmfusion-free,rpmfusion-free-updates,rpmfusion-nonfree,rpmfusion-nonfree-updates"

# install_priority [--official-repo=ID] PKG...
# Each name is resolved independently so Terra-only and Fusion/Fedora-only
# packages in one call do not fail the whole transaction.
install_priority() {
  local official=()
  local pkg
  while [[ ${1-} == --official-repo=* ]]; do
    official+=(--enablerepo="${1#--official-repo=}")
    shift
  done
  for pkg in "$@"; do
    if rpm -q "${pkg}" >/dev/null 2>&1; then
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

# Try each name in order until one installs.
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

swap_ffmpeg_priority() {
  if rpm -q ffmpeg >/dev/null 2>&1; then
    return 0
  fi
  if rpm -q ffmpeg-free >/dev/null 2>&1; then
    if dnf5 -y swap --enablerepo="${TERRA_REPOS}" --allowerasing ffmpeg-free ffmpeg; then
      return 0
    fi
    if dnf5 -y swap --enablerepo="${FUSION_REPOS}" --allowerasing ffmpeg-free ffmpeg; then
      return 0
    fi
  fi
  install_priority ffmpeg
}
