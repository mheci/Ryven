#!/bin/bash
# Fedora 44 KDE: Plasma Login Manager instead of SDDM.

set -ouex pipefail

dnf5 -y install plasma-login-manager kcm-plasmalogin
systemctl enable --force plasmalogin.service
systemctl disable sddm.service || true
systemctl mask sddm.service || true
