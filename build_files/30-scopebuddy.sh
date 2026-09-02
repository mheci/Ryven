#!/bin/bash
# gamescope + ScopeBuddy (Terra). terra-gamescope in 38 may already provide gamescope.

set -ouex pipefail

dnf5 -y install --enablerepo=terra jq ScopeBuddy

if ! command -v gamescope >/dev/null 2>&1; then
  dnf5 -y install --enablerepo=terra gamescope
fi

if command -v scopebuddy >/dev/null && [[ ! -e /usr/bin/scb ]]; then
  ln -sf scopebuddy /usr/bin/scb
fi
