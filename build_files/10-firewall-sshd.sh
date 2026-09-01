#!/bin/bash
# Default deny inbound via firewalld. SSH server stays disabled.

set -ouex pipefail

dnf5 -y install firewalld

systemctl enable firewalld.service
systemctl disable sshd.service 2>/dev/null || true
systemctl mask sshd.service 2>/dev/null || true
