#!/bin/bash
set -ouex pipefail

dnf5 -y install chrony

systemctl enable chronyd.service
systemctl disable systemd-timesyncd.service 2>/dev/null || true
systemctl mask systemd-timesyncd.service 2>/dev/null || true
