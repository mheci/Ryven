#!/bin/bash
# Cardwire eBPF GPU manager (Terra). Enable daemon; do not force laptop hybrid.

set -ouex pipefail

dnf5 -y install --enablerepo=terra cardwire
systemctl enable cardwired.service
