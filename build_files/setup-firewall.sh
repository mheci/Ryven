#!/usr/bin/env bash
# Configure firewalld workstation defaults. No UPnP, no open SSH, mDNS allowed for LAN gaming.
set -euo pipefail

systemctl enable firewalld.service
firewall-offline-cmd --set-default-zone=workstation
# mDNS/Bonjour/LAN discovery
firewall-offline-cmd --add-service=mdns
# Steam P2P/voice ranges handled via STUN, no manual port opens needed.
echo "Firewalld workstation zone configured."
