#!/bin/bash
# Cardwire eBPF GPU manager (Terra). Enable daemon; do not force laptop hybrid.

set -ouex pipefail

dnf5 -y install --enablerepo=terra --skip-unavailable --skip-broken cardwire
systemctl enable cardwired.service || true
