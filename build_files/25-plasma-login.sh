#!/bin/bash
# Fedora 44 KDE: Plasma Login Manager instead of SDDM.

set -ouex pipefail

dnf5 -y install plasma-login-manager kcm-plasmalogin
systemctl enable --force plasmalogin.service
if [[ -f /usr/lib/systemd/system/sddm.service ]] || systemctl list-unit-files sddm.service >/dev/null 2>&1; then
  systemctl disable sddm.service
  systemctl mask sddm.service
fi
