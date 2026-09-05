#!/usr/bin/env bash
# Host-side fetch of the always-latest Pi coding agent (pi.dev) into the
# build context (_build/pi/), mirroring ci/fetch-browsers.sh. Pi is pure JS
# and installs with --ignore-scripts (upstream's documented invocation), so
# the staged npm tree is relocatable: the image build extracts it into /usr
# (compose.sh: install_pi). nodejs+npm are already installed in every Ryven
# image, so nothing else is needed at runtime.
#
#   _build/pi/pi-<version>.tar.gz   bin/ + lib/node_modules/ tree for /usr
#
# Fail-closed: any install/verification failure exits non-zero with the
# error visible in the step log; an explicit size guard catches silent
# empty payloads.
set -euox pipefail

pkg='@earendil-works/pi-coding-agent'
stage='_build/pi/stage'

rm -rf _build/pi
mkdir -p "${stage}"
npm install -g --ignore-scripts --no-fund --no-audit --prefix "${stage}" "${pkg}@latest"

[[ -x ${stage}/bin/pi ]] || { echo 'pi binary missing after staged install' >&2; exit 1; }
ver=$(node -p "require('${PWD}/${stage}/lib/node_modules/${pkg}/package.json').version")
[[ -n ${ver} ]] || { echo 'could not read staged pi version' >&2; exit 1; }

tar -C "${stage}" -czpf "_build/pi/pi-${ver}.tar.gz" bin lib
sz=$(stat -c%s "_build/pi/pi-${ver}.tar.gz")
(( sz > 500000 )) || { echo "pi tarball suspiciously small (${sz} bytes)" >&2; exit 1; }
echo "pi ${ver} staged -> _build/pi/pi-${ver}.tar.gz (${sz} bytes)"
