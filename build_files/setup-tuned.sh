#!/usr/bin/env bash
# Basic retry helper for transient network failures
try() { for i in 1 2 3; do "$@" && return 0; echo "  retry $i/3 ($*)"; sleep 5; done; return 1; }
# Install ryven-gaming tuned profile, tuned + tuned-ppd, sysctl/limits/uaccess defaults.
set -euo pipefail
shopt -s nullglob

# Mask power-profiles-daemon (tuned-ppd replaces it)
systemctl mask --no-reload power-profiles-daemon.service

# Install tuned + tuned-ppd + desktop OOM (nohang replaces systemd-oomd)
dnf5 install -y --skip-unavailable tuned tuned-ppd nohang
systemctl mask --no-reload systemd-oomd.service systemd-oomd.socket
systemctl enable --no-reload tuned.service nohang-desktop.service scx_lavd.service

# Copy tuned profile from our system_files
cp -r system_files/common/usr/lib/tuned/ryven-gaming /usr/lib/tuned/
# tuned-adm profile tries to talk to DBus/tuned daemon which doesn't run in container; set default via symlink
ln -sf /usr/lib/tuned/ryven-gaming /etc/tuned/active_profile 2>/dev/null || true
echo "ryven-gaming" > /etc/tuned/active_profile 2>/dev/null || true
tuned-adm profile ryven-gaming 2>/dev/null || echo "(tuned daemon not running in container; profile set via active_profile)"

# Copy system configs
cp system_files/common/usr/lib/sysctl.d/*.conf /usr/lib/sysctl.d/
cp system_files/common/usr/lib/security/limits.d/*.conf /usr/lib/security/limits.d/
cp system_files/common/usr/lib/udev/rules.d/*.rules /usr/lib/udev/rules.d/
cp system_files/common/usr/lib/modules-load.d/*.conf /usr/lib/modules-load.d/
cp system_files/common/usr/lib/modprobe.d/*.conf /usr/lib/modprobe.d/
cp system_files/common/usr/lib/environment.d/*.conf /usr/lib/environment.d/
cp system_files/common/usr/lib/systemd/system-environment-generators/* /usr/lib/systemd/system-environment-generators/
chmod +x /usr/lib/systemd/system-environment-generators/*
cp system_files/common/usr/share/polkit-1/actions/*.policy /usr/share/polkit-1/actions/

# Create groups system-sysusers
cp system_files/common/usr/lib/sysusers.d/*.conf /usr/lib/sysusers.d/
systemd-sysusers

# Disable zram-generator, zswap configured via kargs
systemctl mask --no-reload systemd-zram-setup@zram0.service zram-swap.service dev-zram0.swap 2>/dev/null || true
rm -f /usr/lib/systemd/zram-generator.conf 2>/dev/null || true

# Coredump disable
systemctl mask --no-reload systemd-coredump.socket systemd-coredump.service 2>/dev/null || true

# Wireplumber ordering for NVIDIA HDMI audio
cp build_files/wireplumber-after-nvidia.conf /usr/lib/systemd/user/wireplumber.service.d/ 2>/dev/null || mkdir -p /usr/lib/systemd/user/wireplumber.service.d/

echo "Tuned/ryven-gaming profile active: $(tuned-adm active)"
