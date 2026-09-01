#!/bin/bash
# Kyber I/O scheduler where the block device exposes the sysfs knob.

set -ouex pipefail

mkdir -p /usr/lib/udev/rules.d
cat >/usr/lib/udev/rules.d/60-ryven-kyber.rules <<'EOF'
# Skip NVMe devices that only advertise "none".
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd*|vd*|mmcblk*", ATTR{queue/scheduler}=="*kyber*", ATTR{queue/scheduler}="kyber"
EOF
