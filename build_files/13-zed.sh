#!/bin/bash
# Zed: Terra zed-nightly, else zed.

set -ouex pipefail

if ! dnf5 -y install --enablerepo=terra zed-nightly; then
  dnf5 -y install --enablerepo=terra zed
fi
