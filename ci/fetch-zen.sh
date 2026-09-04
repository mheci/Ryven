#!/usr/bin/env bash
# Host-side fetch of the latest Zen Browser x86_64 release tarball into the
# build context (_build/zen/), run as a CI step on the runner. The image
# installs it from /ctx (install_zen in compose.sh) — no network in the
# container. Official upstream releases only; fail-closed on any error.
set -euo pipefail

api=$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors \
  https://api.github.com/repos/zen-browser/desktop/releases/latest)
url=$(jq -r '.assets[] | select(.name | test("linux-x86_64\\.tar\\.(bz2|xz|gz)$")) | .browser_download_url' <<<"${api}" | head -n1)
[[ -n ${url} && ${url} != null ]] || { echo 'Zen: x86_64 tarball missing in latest release' >&2; exit 1; }
tag=$(jq -r '.tag_name' <<<"${api}")
echo "Zen: ${tag} ${url##*/}"
mkdir -p _build/zen
curl -fsSL --proto '=https' --retry 3 --retry-all-errors --connect-timeout 30 --max-time 900 \
  -o "_build/zen/${url##*/}" "${url}"
ls -l _build/zen/
test -s _build/zen/* || { echo 'Zen: tarball empty after download' >&2; exit 1; }
echo 'Zen fetch done'
