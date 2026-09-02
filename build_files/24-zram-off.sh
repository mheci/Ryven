#!/bin/bash
# zram off; zswap stays enabled via kargs.d/10-zswap.toml.

set -ouex pipefail

if rpm -q zram-generator-defaults >/dev/null 2>&1 || rpm -q zram-generator >/dev/null 2>&1; then
  dnf5 -y remove zram-generator-defaults zram-generator
fi
mkdir -p /usr/lib/systemd /etc/systemd/system
printf '%s\n' '# Ryven: zram disabled. Compressed RAM is zswap (see kargs.d/10-zswap.toml).' \
  >/usr/lib/systemd/zram-generator.conf
ln -sfn /dev/null /etc/systemd/system/systemd-zram-setup@zram0.service
systemctl mask systemd-zram-setup@zram0.service
