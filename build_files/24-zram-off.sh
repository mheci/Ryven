#!/bin/bash
# zram off; zswap stays enabled via kargs.d/10-zswap.toml.

set -ouex pipefail

dnf5 -y remove zram-generator-defaults zram-generator || true
mkdir -p /usr/lib/systemd /etc/systemd/system
# Empty generator config means no zram device.
printf '%s\n' '# Ryven: zram disabled. Compressed RAM is zswap (see kargs.d/10-zswap.toml).' \
  >/usr/lib/systemd/zram-generator.conf
ln -sf /dev/null /etc/systemd/system/systemd-zram-setup@zram0.service || true
systemctl mask systemd-zram-setup@zram0.service || true
