#!/usr/bin/env bash
# Basic retry helper for transient network failures
try() { for i in 1 2 3; do "$@" && return 0; echo "  retry $i/3 ($*)"; sleep 5; done; return 1; }
# Install ryven-gaming tuned profile, tuned + tuned-ppd, sysctl/limits/uaccess defaults.
set -euo pipefail
shopt -s nullglob

# Mask power-profiles-daemon (tuned-ppd replaces it)
systemctl mask --no-reload power-profiles-daemon.service 2>/dev/null || true

# Install tuned + tuned-ppd + desktop OOM (nohang replaces systemd-oomd)
dnf5 install -y --skip-unavailable tuned tuned-ppd nohang
systemctl mask --no-reload systemd-oomd.service systemd-oomd.socket 2>/dev/null || true
systemctl enable --no-reload tuned.service nohang-desktop.service 2>/dev/null || true

# Copy tuned profile from our system_files
cp -r system_files/common/usr/lib/tuned/ryven-gaming /usr/lib/tuned/
# tuned-adm profile tries to talk to DBus/tuned daemon which doesn't run in container; set default by writing profile name.
# /etc/tuned/active_profile must be a text file (name), not the symlink tuned-adm would create.
mkdir -p /etc/tuned
rm -rf /etc/tuned/active_profile
echo "ryven-gaming" > /etc/tuned/active_profile
# Also set via profile_mode=manual so tuned doesn't auto-switch at boot
mkdir -p /etc/tuned
echo "manual" > /etc/tuned/profile_mode 2>/dev/null || true
tuned-adm profile ryven-gaming >/dev/null 2>&1 || echo "(tuned daemon not running in container; profile set via active_profile file)"

# Copy system configs
# Copy config files safely (use for loops so empty globs don't cause cp errors)
for f in system_files/common/usr/lib/sysctl.d/*.conf; do [ -f "$f" ] && cp "$f" /usr/lib/sysctl.d/; done
for f in system_files/common/usr/lib/security/limits.d/*.conf; do [ -f "$f" ] && cp "$f" /usr/lib/security/limits.d/; done
for f in system_files/common/usr/lib/udev/rules.d/*.rules; do [ -f "$f" ] && cp "$f" /usr/lib/udev/rules.d/; done
for f in system_files/common/usr/lib/modules-load.d/*.conf; do [ -f "$f" ] && cp "$f" /usr/lib/modules-load.d/; done
for f in system_files/common/usr/lib/modprobe.d/*.conf; do [ -f "$f" ] && cp "$f" /usr/lib/modprobe.d/; done
for f in system_files/common/usr/lib/environment.d/*.conf; do [ -f "$f" ] && cp "$f" /usr/lib/environment.d/; done
for f in system_files/common/usr/lib/systemd/system-environment-generators/*; do
    if [ -f "$f" ]; then
        cp "$f" /usr/lib/systemd/system-environment-generators/
        chmod +x "/usr/lib/systemd/system-environment-generators/$(basename "$f")"
    fi
done
for f in system_files/common/usr/share/polkit-1/actions/*.policy; do [ -f "$f" ] && cp "$f" /usr/share/polkit-1/actions/; done

# Create groups system-sysusers
for f in system_files/common/usr/lib/sysusers.d/*.conf; do [ -f "$f" ] && cp "$f" /usr/lib/sysusers.d/; done
systemd-sysusers

# Disable zram-generator, zswap configured via kargs
systemctl mask --no-reload systemd-zram-setup@zram0.service zram-swap.service dev-zram0.swap 2>/dev/null || true
rm -f /usr/lib/systemd/zram-generator.conf 2>/dev/null || true

# Coredump disable
systemctl mask --no-reload systemd-coredump.socket systemd-coredump.service 2>/dev/null || true

# Wireplumber ordering for NVIDIA HDMI audio
cp build_files/wireplumber-after-nvidia.conf /usr/lib/systemd/user/wireplumber.service.d/ 2>/dev/null || mkdir -p /usr/lib/systemd/user/wireplumber.service.d/

echo "Tuned/ryven-gaming profile active: $(cat /etc/tuned/active_profile) (container build; tuned daemon not running)"
