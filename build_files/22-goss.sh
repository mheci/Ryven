#!/bin/bash
# Build-time image invariants (Goss spec + equivalent checks).
# No GPU; systemd is not PID 1. Fail the image if a check fails.

set -ouex pipefail

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

check "firefox rpm" rpm -q firefox
check "git on PATH" command -v git
check "gh on PATH" command -v gh
check "mise on PATH" command -v mise
check "ujust wrapper" test -x /usr/bin/ujust
check "ryven justfile" test -f /usr/share/ryven/justfile
check "chronyd enabled" bash -c '[[ $(systemctl is-enabled chronyd.service) == enabled ]]'
check "sshd not enabled" bash -c 's=$(systemctl is-enabled sshd.service 2>/dev/null || true); [[ $s != enabled ]]'
check "firewalld enabled" bash -c '[[ $(systemctl is-enabled firewalld.service) == enabled ]]'
check "nvidia kmod present" bash -c 'find /usr/lib/modules -name "nvidia*.ko*" -print -quit | grep -q .'
check "no firefox flatpak" bash -c '! command -v flatpak >/dev/null || ! flatpak info --system org.mozilla.firefox >/dev/null 2>&1'
check "docker group empty or absent" bash -c '
  if getent group docker >/dev/null; then
    members=$(getent group docker | cut -d: -f4)
    [[ -z ${members} ]]
  else
    true
  fi
'

if [[ ${fail} -ne 0 ]]; then
  echo "Image invariant checks failed." >&2
  exit 1
fi

echo "Image invariant checks passed."
