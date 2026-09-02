#!/bin/bash
# Terra f44 Name: ScopeBuddy.

set -ouex pipefail
# shellcheck source=repo-priority.sh
source /ctx/repo-priority.sh

install_priority jq ScopeBuddy

if command -v scopebuddy >/dev/null && [[ ! -e /usr/bin/scb ]]; then
  ln -sf scopebuddy /usr/bin/scb
fi
