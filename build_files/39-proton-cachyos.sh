#!/bin/bash
# Official proton-cachyos SLR tarball into Steam compatibilitytools.d.
# Compiling Valve Proton in this image is multi-hour; ship the CachyOS build.
# Not curl|sh — pinned release URL + sha512.

set -ouex pipefail

VER=11.0-20260703-slr
BASE="https://github.com/CachyOS/proton-cachyos/releases/download/cachyos-${VER}"
TAR="proton-cachyos-${VER}-x86_64.tar.xz"
SUM="proton-cachyos-${VER}-x86_64.sha512sum"
DEST=/usr/share/steam/compatibilitytools.d

dnf5 -y install tar xz curl coreutils

mkdir -p /tmp/proton-cachyos "${DEST}"
curl -fsSL -o "/tmp/proton-cachyos/${SUM}" "${BASE}/${SUM}"
curl -fL --retry 3 -o "/tmp/proton-cachyos/${TAR}" "${BASE}/${TAR}"
(cd /tmp/proton-cachyos && sha512sum -c "${SUM}")

tar -xJf "/tmp/proton-cachyos/${TAR}" -C "${DEST}"
# Steam looks for a directory containing compatibilitytool.vdf
if [[ ! -f ${DEST}/proton-cachyos/compatibilitytool.vdf ]] && \
   [[ ! -f ${DEST}/proton-cachyos-${VER}/compatibilitytool.vdf ]]; then
  vdf=$(find "${DEST}" -name compatibilitytool.vdf -print -quit)
  if [[ -z ${vdf} ]]; then
    echo "proton-cachyos tarball missing compatibilitytool.vdf" >&2
    find "${DEST}" -maxdepth 3 >&2
    exit 1
  fi
fi

rm -rf /tmp/proton-cachyos
echo "proton-cachyos ${VER} installed under ${DEST}"
