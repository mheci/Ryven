#!/usr/bin/env bash
# Host-side fetch of the always-latest browser payloads into the build
# context (_build/), run as a CI step on the runner. The image build then
# installs them from /ctx (install_betterbird / install_firefox /
# install_zen / install_brave_origin in compose.sh).
#
#   _build/betterbird/  betterbird-*.tar.xz   (betterbird.eu listing, CDN first)
#   _build/firefox/     firefox-<ver>.tar.xz  (archive.mozilla.org, SHA512-verified)
#   _build/zen/         zen-<tag>.tar.xz      (zen-browser/desktop GitHub latest)
#   _build/brave/       brave-origin-*.rpm    (brave/brave-browser GitHub latest,
#                                              sha256-verified) + brave-keyring
#                                              (Brave's official repo repodata)
#
# GitHub API calls use GITHUB_TOKEN when present (CI); anonymous otherwise.
# Fail-closed: any fetch/verification failure exits non-zero with the error
# visible in the step log; explicit size guards catch silent empty files.
set -euox pipefail

mkdir -p _build/betterbird _build/firefox _build/zen _build/brave

# ---------------------------------------------------------------- BetterBird
# Source preference: the project's BunnyCDN bulk-download mirror first
# (a CDN built for exactly this; the origin sits on small shared hosting
# that intermittently drops datacenter connections), the origin as
# canonical fallback. Identical listing verified 2026-09-03.
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
  [[ ${base2} != "${base}" ]] && break
done
rel=$(tail -n1 <<<"${files}")
out="_build/betterbird/$(basename "${rel}")"
echo "BetterBird: downloading ${rel}"
if ! curl -fsSL --proto '=https' --retry 2 --retry-all-errors --retry-delay 10 --retry-max-time 900 --connect-timeout 30 --max-time 900 -o "${out}" "${base}/${rel}"; then
  echo "BetterBird: tarball download failed from ${base}; retrying via ${base2}" >&2
  curl -fsSL --proto '=https' --retry 2 --retry-all-errors --retry-delay 10 --retry-max-time 900 --connect-timeout 30 --max-time 900 -o "${out}" "${base2}/${rel}"
fi
test -s "${out}" || { echo 'BetterBird: tarball empty after download' >&2; exit 1; }
echo "BetterBird fetch done: ${out}"

# ------------------------------------------------------------------- helpers
# gh_api URL: GitHub API GET with patience. Uses GITHUB_TOKEN when set
# (registered CI secret; Actions masks it in logs).
gh_api() {
  local auth=()
  [[ -n ${GITHUB_TOKEN:-} ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors --retry-delay 5 \
    --max-time 90 "${auth[@]}" -H 'Accept: application/vnd.github+json' "$1"
}

# ------------------------------------------------------------------- Firefox
# Latest stable from Mozilla's canonical release infrastructure:
# product-details version pointer + archive.mozilla.org payload, verified
# against the release's SHA512SUMS (same trust model as the Fedora RPM).
ffver=$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors --max-time 60 \
  'https://product-details.mozilla.org/1.0/firefox_versions.json' |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["LATEST_FIREFOX_VERSION"])')
[[ ${ffver} =~ ^[0-9][0-9.]*$ ]] || { echo "Firefox: bad version '${ffver}'" >&2; exit 1; }
ffbase="https://archive.mozilla.org/pub/firefox/releases/${ffver}"
out="_build/firefox/firefox-${ffver}.tar.xz"
echo "Firefox: downloading ${ffver}"
curl -fsSL --proto '=https' --retry 3 --retry-all-errors --retry-delay 10 \
  --retry-max-time 900 --max-time 900 -o "${out}" \
  "${ffbase}/linux-x86_64/en-US/firefox-${ffver}.tar.xz"
test -s "${out}" || { echo 'Firefox: tarball empty after download' >&2; exit 1; }
curl -fsSL --proto '=https' --retry 3 --retry-all-errors --max-time 300 \
  -o /tmp/firefox-SHA512SUMS "${ffbase}/SHA512SUMS"
want=$(awk -v f="linux-x86_64/en-US/firefox-${ffver}.tar.xz" '$2 == f {print $1; exit}' /tmp/firefox-SHA512SUMS)
[[ -n ${want} ]] || { echo 'Firefox: no SHA512SUMS entry for the x86_64 en-US tarball' >&2; exit 1; }
echo "${want}  ${out}" | sha512sum -c - || { echo 'Firefox: SHA512 mismatch' >&2; exit 1; }
echo "Firefox fetch done: ${out} (sha512 verified)"

# ----------------------------------------------------------------------- Zen
# Latest stable release tarball from zen-browser/desktop (GitHub /releases/
# latest excludes drafts and prereleases).
zsel=$(gh_api 'https://api.github.com/repos/zen-browser/desktop/releases/latest' |
  python3 -c '
import json,sys
r = json.load(sys.stdin)
for a in r.get("assets", []):
    if a.get("name") == "zen.linux-x86_64.tar.xz":
        print(r.get("tag_name",""), a["browser_download_url"])
        break
')
ztag=${zsel%% *}; zurl=${zsel#* }
[[ -n ${ztag} && -n ${zurl} && ${zurl} == https://* ]] || { echo 'Zen: no linux-x86_64 tarball in latest release' >&2; exit 1; }
out="_build/zen/zen-${ztag}.tar.xz"
echo "Zen: downloading ${ztag}"
curl -fsSL --proto '=https' --retry 3 --retry-all-errors --retry-delay 10 \
  --retry-max-time 1800 --max-time 1800 -o "${out}" "${zurl}"
test -s "${out}" || { echo 'Zen: tarball empty after download' >&2; exit 1; }
echo "Zen fetch done: ${out}"

# --------------------------------------------------------------- Brave Origin
# Latest brave-origin x86_64 RPM from brave/brave-browser GitHub releases,
# verified against the release's published .sha256 asset.
bsel=$(gh_api 'https://api.github.com/repos/brave/brave-browser/releases/latest' |
  python3 -c '
import json,re,sys
r = json.load(sys.stdin)
pat = re.compile(r"^brave-origin-[0-9][0-9.]*-[0-9]+\.x86_64\.rpm$")
for a in r.get("assets", []):
    if pat.match(a.get("name","")):
        print(r.get("tag_name",""), a["browser_download_url"])
        break
')
btag=${bsel%% *}; burl=${bsel#* }
[[ -n ${btag} && -n ${burl} && ${burl} == https://* ]] || { echo 'Brave: no brave-origin x86_64 RPM in latest release' >&2; exit 1; }
out="_build/brave/$(basename "${burl}")"
echo "Brave Origin: downloading ${btag}"
curl -fsSL --proto '=https' --retry 3 --retry-all-errors --retry-delay 10 \
  --retry-max-time 1800 --max-time 1800 -o "${out}" "${burl}"
test -s "${out}" || { echo 'Brave: RPM empty after download' >&2; exit 1; }
curl -fsSL --proto '=https' --retry 3 --retry-all-errors --max-time 120 \
  -o "${out}.sha256" "${burl}.sha256"
sum=$(awk '{print $1; exit}' "${out}.sha256")
[[ ${sum} =~ ^[0-9a-f]{64}$ ]] || { echo 'Brave: malformed sha256 asset' >&2; exit 1; }
echo "${sum}  ${out}" | sha256sum -c - || { echo 'Brave: sha256 mismatch' >&2; exit 1; }
rm -f "${out}.sha256"

# brave-keyring: the RPM's only non-Fedora Requires (vendor GPG key package).
# Resolve the newest one from Brave's official repo repodata (no .repo file
# is ever installed on the image; compose installs the fetched RPMs locally).
repomd=$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors --max-time 60 \
  'https://brave-browser-rpm-release.s3.brave.com/x86_64/repodata/repomd.xml')
primary=$(grep -o 'href="repodata/[^"]*primary\.xml\.gz"' <<<"${repomd}" | head -1 | sed 's/^href="//; s/"$//')
[[ -n ${primary} ]] || { echo 'Brave: no primary.xml.gz in repomd' >&2; exit 1; }
curl -fsSL --proto '=https' --retry 3 --retry-all-errors --max-time 300 \
  -o /tmp/brave-primary.xml.gz "https://brave-browser-rpm-release.s3.brave.com/x86_64/${primary}"
kloc=$(python3 - <<'PYEOF'
import gzip, re
data = gzip.open('/tmp/brave-primary.xml.gz', 'rt').read()
best = None
for p in re.findall(r'<package type="rpm">(.*?)</package>', data, re.S):
    if re.search(r'<name>brave-keyring</name>', p) is None:
        continue
    v = re.search(r'<version epoch="\d+" ver="([^"]+)" rel="([^"]+)"', p)
    l = re.search(r'<location href="([^"]+)"', p)
    if not v or not l:
        continue
    try:
        key = tuple(int(x) for x in v.group(1).split('.'))
    except ValueError:
        continue
    if best is None or key > best[0]:
        best = (key, l.group(1))
print(best[1] if best else '')
PYEOF
)
[[ -n ${kloc} ]] || { echo 'Brave: no brave-keyring package in repo metadata' >&2; exit 1; }
curl -fsSL --proto '=https' --retry 3 --retry-all-errors --max-time 300 \
  -o "_build/brave/$(basename "${kloc}")" \
  "https://brave-browser-rpm-release.s3.brave.com/x86_64/${kloc}"
test -s "_build/brave/$(basename "${kloc}")" || { echo 'Brave: keyring RPM empty' >&2; exit 1; }
echo "Brave Origin fetch done: ${out} (sha256 verified) + $(basename "${kloc}")"
