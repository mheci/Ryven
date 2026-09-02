#!/bin/bash
# Steam: Terra Name: steam, then RPM Fusion nonfree.

set -ouex pipefail

if ! dnf5 -y install --enablerepo=terra steam; then
  dnf5 -y install --enablerepo=rpmfusion-nonfree steam
fi
