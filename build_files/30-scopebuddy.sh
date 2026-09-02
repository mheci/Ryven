#!/bin/bash
# ScopeBuddy (Terra Name: ScopeBuddy). Gamescope is terra-gamescope in 38.

set -ouex pipefail

dnf5 -y install --enablerepo=terra jq ScopeBuddy

if command -v scopebuddy >/dev/null && [[ ! -e /usr/bin/scb ]]; then
  ln -sf scopebuddy /usr/bin/scb
fi
