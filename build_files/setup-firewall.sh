#!/usr/bin/env bash
# Basic retry helper for transient network failures
try() { for i in 1 2 3; do "$@" && return 0; echo "  retry $i/3 ($*)"; sleep 5; done; return 1; }
# Configure firewalld workstation defaults. No UPnP, no open SSH, mDNS allowed for LAN gaming.
set -euo pipefail
shopt -s nullglob

systemctl enable --no-reload firewalld.service 2>/dev/null || true
firewall-offline-cmd --set-default-zone=workstation
# mDNS/Bonjour/LAN discovery
firewall-offline-cmd --add-service=mdns
# Steam P2P/voice ranges handled via STUN, no manual port opens needed.
echo "Firewalld workstation zone configured."
