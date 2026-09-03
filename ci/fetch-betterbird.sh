#!/usr/bin/env bash
# Host-side fetch of the latest BetterBird x86_64 release into the build
# context (_build/betterbird/), run as a CI step on the runner. The image
# build then installs it from /ctx (install_betterbird in the build
# scripts) — no network in the container.
#
# Source preference: the project's BunnyCDN bulk-download mirror first
# (a CDN built for exactly this; the origin sits on small shared hosting
# that intermittently drops datacenter connections), the origin as
# canonical fallback. Identical listing verified 2026-09-03.
#
# Fail-closed: any fetch/selection/download failure exits non-zero with
# the curl error visible in the step log; an explicit test -s guards
# against a silent empty file.
set -euox pipefail

SOURCES=(
  'https://betterbird-downloads.b-cdn.net'
  'https://www.betterbird.eu/downloads'
)

listing=''
for base in "${SOURCES[@]}"; do
  # --max-time caps each attempt (a silently dropped connection must not
  # consume the whole retry budget).
  if listing=$(curl -fsSL --proto '=https' --max-time 60 --retry 2 --retry-all-errors --retry-delay 5 --retry-max-time 150 --connect-timeout 30 "${base}/"); then
    break
  fi
  echo "BetterBird: listing fetch failed from ${base}; trying next source" >&2
done
if [[ -z ${listing} ]]; then
  echo 'BetterBird: listing fetch failed from all sources' >&2
  exit 1
fi
echo "BetterBird: listing fetched from ${base} (${#listing} bytes)"

# Current release of each ESR line first ("-latest-" marker), then every
# plain en-US x86_64 build. Exclude the Previous/ archive; highest
# version wins.
files=$(grep -oE 'LinuxArchive/betterbird-[^"]*-latest-[^"]*\.en-US\.linux-x86_64\.tar\.xz' <<<"${listing}" | grep -v 'Previous/' | LC_ALL=C sort -V || true)
if [[ -z ${files} ]]; then
  files=$(grep -oE 'LinuxArchive/betterbird-[^"]*\.en-US\.linux-x86_64\.tar\.xz' <<<"${listing}" | grep -vE 'Previous/|-latest-' | LC_ALL=C sort -V || true)
fi
if [[ -z ${files} ]]; then
  echo 'BetterBird: no x86_64 tarball found in the download listing' >&2
  exit 1
fi

base2=''
for base2 in "${SOURCES[@]}"; do
  [[ ${base2} != ${base} ]] && break
done
rel=$(tail -n1 <<<"${files}")
out="_build/betterbird/$(basename "${rel}")"
mkdir -p _build/betterbird
echo "BetterBird: downloading ${rel}"
if ! curl -fsSL --proto '=https' --retry 2 --retry-all-errors --retry-delay 10 --retry-max-time 900 --connect-timeout 30 --max-time 900 -o "${out}" "${base}/${rel}"; then
  echo "BetterBird: tarball download failed from ${base}; retrying via ${base2}" >&2
  curl -fsSL --proto '=https' --retry 2 --retry-all-errors --retry-delay 10 --retry-max-time 900 --connect-timeout 30 --max-time 900 -o "${out}" "${base2}/${rel}"
fi
ls -l "${out}"
test -s "${out}" || { echo 'BetterBird: tarball empty after download' >&2; exit 1; }
echo "BetterBird fetch done: ${out}"
