#!/bin/bash
# gamescope + ScopeBuddy (Terra) for nested gamescope on Plasma.

set -ouex pipefail

dnf5 -y install --enablerepo=terra --skip-unavailable --skip-broken \
  gamescope \
  gamescope-libs \
  ScopeBuddy \
  scopebuddy \
  jq

if command -v scopebuddy >/dev/null && [[ ! -e /usr/bin/scb ]]; then
  ln -sf scopebuddy /usr/bin/scb
fi
