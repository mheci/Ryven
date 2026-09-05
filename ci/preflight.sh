#!/bin/bash
# NEVRA preflight: fail the run in MINUTES when a ladder package name has
# no literal provider, instead of dying 10+ minutes into the image build.
#
# Runs in a pinned fedora:44 container (same release the images target, so
# $releasever-gated repos resolve identically), sources the REAL repo setup
# from build_files/compose.sh (single source of truth — no duplicated repo
# knowledge except the two repofile URLs marked below), then resolves every
# package token the image scripts feed the ladder.
#
# Strictness mirrors _ladder_once: a token passes only if some available
# package's literal NAME equals it (provides do NOT count — dnf resolving
# `npm` via provides still fails the ladder's `rpm -q npm` check).
# Group semantics mirror the callers:
#   install_priority ...  -> every token must resolve (gate)
#   install_any a b ...   -> at least one token must resolve (gate)
#   missing_pkgs array    -> warning only (nett00n COPR backstops it)
#   `if`-ledder calls     -> gate only when the next line dies on a miss
#                            (greetd); tolerated misses (terra-gamescope)
#                            and covered fallbacks (wl-clip-persist cargo)
#                            are warning-only. The real build stays
#                            fail-closed in all cases.
#
# releasever-gated repofile URLs below hardcode Fedora 44, matching compose.
# When the images move to the next Fedora release, bump these together with
# compose's Fedora_44 references and the fedora:44 image in build.yml.
set -euo pipefail
CTX=${CTX:-/ctx}
# shellcheck source=/dev/null
source "${CTX}/build_files/compose.sh"

say 'preflight repo union (read-only queries)'
bootstrap_terra
bootstrap_fusion
# Extra sources compose enables per-transaction (keep in sync):
#  - razer repofile: same URL as build.sh vendor_repo_install call
dnf5 -y config-manager addrepo --overwrite \
  --from-repofile='https://download.opensuse.org/repositories/hardware:/razer/Fedora_44/hardware:razer.repo' \
  >/tmp/preflight.log 2>&1 || die 'preflight: razer repofile failed'
#  - nett00n/hyprland COPR: same source as the build-kunzite.sh last resort
dnf5 -y config-manager addrepo --overwrite \
  --from-repofile='https://copr.fedorainfracloud.org/coprs/nett00n/hyprland/repo/fedora-44/nett00n-hyprland-fedora-44.repo' \
  >>/tmp/preflight.log 2>&1 || die 'preflight: hyprland COPR repofile failed'
#  - bieszczaders/kernel-cachyos-lto COPR: same source as swap_kernel_cachyos
dnf5 -y config-manager addrepo --overwrite \
  --from-repofile='https://copr.fedorainfracloud.org/coprs/bieszczaders/kernel-cachyos-lto/repo/fedora-44/bieszczaders-kernel-cachyos-lto-fedora-44.repo' \
  >>/tmp/preflight.log 2>&1 || die 'preflight: cachyos COPR repofile failed'
#  - Browsers need no repo here: Firefox/Zen/Brave Origin install from
#    host-fetched local files (ci/fetch-browsers.sh -> /ctx/_build), and
#    their only ladder tokens (gtk3 libXt dbus-glib alsa-lib) are Fedora
#    packages already covered by the base union.
#  - rpmfusion-free-tainted: build.sh installs the tainted release RPM then
#    libdvdcss from it; mirror that here so libdvdcss resolves.
dnf5 -y install --enablerepo=rpmfusion-free \
  rpmfusion-free-release-tainted >>/tmp/preflight.log 2>&1 || die 'preflight: tainted release failed'
# bootstrap_* leave repos disabled at rest; enable the whole union by ID.
# (set -e discipline: repolist failing silently would kill the script with
# no message, so capture, verify non-empty, then loop.)
repo_ids=$(dnf5 repolist --all 2>/tmp/preflight-err.log | awk 'NR > 1 {print $1}' || true)
[[ -n ${repo_ids} ]] || { tail -n 10 /tmp/preflight-err.log >&2 || true; die 'preflight: repolist empty/failed'; }
for id in ${repo_ids}; do
  case "${id}" in
    terra*|rpmfusion*|fedora*|updates*|*razer*|*hyprland*|*nett00n*|*cachyos*|*bieszczaders*|*tainted*)
      # NOTE: dnf5 uses the `enable` subcommand, not --set-enabled
      # (the flag form errors out; with || true that left repos disabled).
      dnf5 config-manager enable "${id}" >>/tmp/preflight.log 2>&1 || die "preflight: cannot enable repo ${id}" ;;
  esac
done
repo_on=$(dnf5 repolist --enabled 2>/dev/null | awk 'NR > 1 {print $1}') || die 'preflight: enabled repolist failed'
# shellcheck disable=SC2086
echo "preflight: enabled repos ($(echo ${repo_on} | wc -w)): $(echo ${repo_on} | tr '\n' ' ')"

say 'preflight token extraction'
# fedora container images ship dnf5 (C++) but no python3; the battle-tested
# tokenizer below needs it. (gawk/coreutils/grep are already present —
# the enable loop above used awk successfully.)
dnf5 -y install python3 >>/tmp/preflight.log 2>&1 || die 'preflight: python3 install failed'
# KIND|GROUP|NAME per ladder token across the three image scripts.
mapfile -t tokens < <(python3 - "${CTX}/build_files"/compose.sh \
    "${CTX}/build_files"/build.sh \
    "${CTX}/build_files"/build-kunzite.sh \
    "${CTX}/build_files"/build-sericea.sh <<'EOF'
import re, sys

def clean(ln):
    # Strip quoted strings BEFORE comments: ${ARR[@]/#/--enablerepo=} style
    # expansions contain # inside double quotes, which is not a comment.
    ln = re.sub(r"'[^']*'", '', ln)
    ln = re.sub(r'"[^"]*"', '', ln)
    ln = re.sub(r'#.*$', '', ln)
    return ln

def names(toks):
    return [t for t in toks if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+%-]*', t)]

out, group = [], 0
for path in sys.argv[1:]:
    with open(path) as f:
        phys = f.read().splitlines()
    # join continuations (clean() strips quotes before comments so # inside
    # "${ARR[@]/#/..}" expansions cannot eat a trailing backslash)
    logical, cur = [], ''
    for ln in phys:
        ln = clean(ln)
        if ln.rstrip().endswith('\\'):
            cur += ln.rstrip()[:-1] + ' '
        else:
            cur += ln
            logical.append(cur)
            cur = ''
    if cur.strip():
        logical.append(cur)
    for i, raw in enumerate(logical):
        s = clean(raw).strip()
        m = re.match(r'if\s+(!\s+)?(install_priority|install_any)\s+(.*)', s)
        if m:
            # conditional ladder call: gate only when a miss dies (check the
            # next line); tolerated misses (terra-gamescope) and covered
            # fallbacks (wl-clip-persist cargo) are warn-only.
            rest = re.split(r';', m.group(3))[0]
            nxt = clean(logical[i + 1]).strip() if i + 1 < len(logical) else ''
            if 'die' in nxt:
                if m.group(2) == 'install_any':
                    group += 1
                    kind = f'any:{group}'
                else:
                    kind = 'require'
            else:
                kind = 'warn'
            for tok in names(rest.split()):
                out.append(f'{kind}|{tok}')
            continue
        full = s
        s = re.split(r'\|\||&&|;', s)[0].strip()
        kind, toks = None, []
        if s.startswith('install_priority '):
            kind, toks = 'require', s.split()[1:]
        elif s.startswith('install_any '):
            group += 1
            kind, toks = f'any:{group}', s.split()[1:]
        elif re.match(r'missing_pkgs=\(', s):
            kind, toks = 'warn', re.findall(r'[^\s()]+', s.split('=', 1)[1])
        elif s.startswith('vendor_repo_install '):
            kind, toks = 'require', s.split()[1:]
        elif re.match(r'(if\s+)?(!\s+)?(_q\s+)?dnf5\s', s):
            # Direct dnf transactions: gate install/swap/distro-sync package
            # args. clean() already dropped quoted strings; flags and
            # redirect/path tokens fail the name pattern below. Removes,
            # upgrades, copr/makecache/repoquery verbs are not gated.
            # (--exclude VALUES are gated too; they exist in the union,
            # e.g. openrazer-kernel-modules-dkms in the razer repo.)
            t = re.sub(r'^(if\s+)?(!\s+)?(_q\s+)?dnf5\s+', '', s).split()
            while t and t[0].startswith('-'):
                t = t[1:]
            if t and t[0] in ('install', 'swap', 'distro-sync'):
                # Hard (require) vs tolerated (warn) mirrors set -e reality:
                # conditionals follow the ladder next-line-die rule; a || die
                # tail (same or next line) or a propagated return/exit is
                # hard; bare lines die under set -e; || true/echo is soft
                # (e.g. kernel modules-extra, which is absent upstream).
                nxt = clean(logical[i + 1]).strip() if i + 1 < len(logical) else ''
                tail = full[len(s):] + ' ' + nxt
                if re.match(r'if\s', full):
                    kind = 'require' if 'die' in nxt else 'warn'
                elif 'die' in tail or re.search(r'\b(return|exit)\b', tail):
                    kind = 'require'
                elif full == s:
                    kind = 'require'
                elif re.match(r'\s*(\|\||&&)', full[len(s):]):
                    kind = 'warn'
                else:
                    kind = 'require'
                args = t[1:]
                while args and args[0].startswith('-'):
                    args = args[1:]
                if t[0] == 'swap':
                    # Outgoing must be installed (local state, e.g. the
                    # libfdk-aac fossil, absent upstream); gate incoming only.
                    args = args[1:]
                toks = args
        if kind is None:
            continue
        for tok in names(toks):
            out.append(f'{kind}|{tok}')
for line in sorted(set(out)):
    print(line)
EOF
)
((${#tokens[@]})) || die 'preflight: extracted zero tokens'
say "preflight resolving ${#tokens[@]} tokens"

# One batched repoquery (single metadata load), literal names only.
mapfile -t names < <(printf '%s\n' "${tokens[@]}" | cut -d'|' -f2 | sort -u)
# Query both bare names and name.arch forms: compose installs arch-suffixed
# NEVRA (vulkan-loader.x86_64, mangohud.i686) and the gate must honor them.
available=$(dnf5 -q repoquery --available --qf '%{name} %{name}.%{arch}\n' -- "${names[@]}" 2>/tmp/preflight-err.log | sort -u) ||
  { tail -n 20 /tmp/preflight-err.log >&2 || true; die 'preflight: repoquery failed (repo metadata unavailable?)'; }
avail=" ${available//$'\n'/ } "

fail=0
check_require() {
  if [[ ${avail} == *" $1 "* ]]; then return 0; fi
  # dnf install also resolves via Provides (Thunar->thunar,
  # fontawesome4-fonts->fontawesome-fonts, shim-x64->shim). Mirror that
  # before calling it a miss (metadata is cached; misses are rare).
  if dnf5 -q repoquery --available --qf '%{name}\n' --whatprovides "$1" 2>/dev/null | grep -q .; then
    echo "preflight: '${1}' resolves via Provides (no literal name)" >&2
    return 0
  fi
  echo "PREFLIGHT-FAIL: no provider for '${1}'" >&2
  fail=1
}
declare -A any_hit=()
while IFS='|' read -r kind name; do
  case "${kind}" in
    require) check_require "${name}" ;;
    any:*) [[ ${avail} == *" ${name} "* ]] && any_hit["${kind}"]=1 ;;
    warn)
      [[ ${avail} == *" ${name} "* ]] || echo "preflight warn: '${name}' ladder-misses (fallback covers it)" ;;
  esac
done < <(printf '%s\n' "${tokens[@]}")
for group in $(printf '%s\n' "${tokens[@]}" | cut -d'|' -f1 | grep '^any:' | sort -u); do
  if [[ -z ${any_hit[${group}]:-} ]]; then
    members=$(printf '%s\n' "${tokens[@]}" | awk -F'|' -v g="${group}" '$1==g{print $2}' | tr '\n' ' ')
    echo "PREFLIGHT-FAIL: no provider for any of [${members}]" >&2
    fail=1
  fi
done
echo "preflight: ${#names[@]} names, $(echo "${available}" | wc -l) literal providers in union"
[[ ${fail} == 0 ]] || die 'preflight: unresolved package names (see PREFLIGHT-FAIL lines)'
say 'preflight passed'
