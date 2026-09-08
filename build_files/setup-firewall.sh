#!/usr/bin/env bash
# Basic retry helper for transient network failures
try() { for i in 1 2 3; do "$@" && return 0; echo "  retry $i/3 ($*)"; sleep 5; done; return 1; }
# Configure firewalld workstation defaults. No UPnP, no open SSH, mDNS allowed for LAN gaming.
set -euo pipefail
shopt -s nullglob

dnf5 install -y --skip-unavailable firewalld 2>/dev/null || true
systemctl enable --no-reload firewalld.service 2>/dev/null || true
if command -v firewall-offline-cmd >/dev/null 2>&1; then
    firewall-offline-cmd --set-default-zone=workstation 2>/dev/null || true
    firewall-offline-cmd --add-service=mdns 2>/dev/null || true
fi
echo "Firewalld workstation zone configured."
