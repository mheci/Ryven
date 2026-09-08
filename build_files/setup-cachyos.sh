#!/usr/bin/env bash
# Basic retry helper for transient network failures
try() { for i in 1 2 3; do "$@" && return 0; echo "  retry $i/3 ($*)"; sleep 5; done; return 1; }
export KERNEL_INSTALL_DIR=/dev/null
export INITRD_POST_UPDATE_DISABLE=true
export DNF5_DISABLE_POST_TRANSACTION_ACTIONS=true
export SYSTEMD_OFFLINE=1

# Enable CachyOS COPR, swap stock Fedora kernel for kernel-cachyos-lto, install CachyOS addons.
# CachyOS addons (schedulers/ananicy/settings) live in a SEPARATE COPR: bieszczaders/kernel-cachyos-addons.
set -euo pipefail

echo "Enabling bieszczaders/kernel-cachyos-lto COPR..."
(dnf5 -y copr enable bieszczaders/kernel-cachyos-lto 2>/dev/null && echo "bieszczaders/kernel-cachyos-lto COPR enabled") || echo "WARNING: bieszczaders/kernel-cachyos-lto COPR unavailable"
echo "Enabling bieszczaders/kernel-cachyos-addons COPR..."
(dnf5 -y copr enable bieszczaders/kernel-cachyos-addons 2>/dev/null && echo "bieszczaders/kernel-cachyos-addons COPR enabled") || echo "WARNING: bieszczaders/kernel-cachyos-addons COPR unavailable"

echo "Installing CachyOS kernel..."
rpm-ostree override remove kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-devel kernel-devel-matched 2>/dev/null || true
dnf5 install -y --skip-unavailable kernel-cachyos-lto kernel-cachyos-lto-devel-matched

echo "Removing Fedora zram-generator-defaults (conflicts with cachyos-settings; we disable zram anyway)"
rpm-ostree override remove zram-generator-defaults 2>/dev/null || dnf5 -y remove zram-generator-defaults || true

echo "Installing CachyOS tuning addons (from addons COPR)..."
# scx-scheds-git is the actively-built package in the addons COPR (stable scx-scheds fails to build)
# scxctl manages scheduler selection; cachyos-settings ships sysctl/udev/modprobe tunings;
# cachyos-ananicy-rules provides the gaming nice rules.
dnf5 install -y --skip-unavailable \
    scx-scheds-git \
    scxctl \
    scx-manager \
    cachyos-settings \
    cachyos-ananicy-rules

# ananicy-cpp daemon: try standard repos first, fall back to addons COPR.
if dnf5 install -y --skip-unavailable ananicy-cpp 2>/dev/null; then
    echo "ananicy-cpp installed from default repos"
else
    echo "ananicy-cpp not in default repos, trying addons COPR..."
    dnf5 install -y --skip-unavailable --repo=copr:copr.fedorainfracloud.org:bieszczaders:kernel-cachyos-addons ananicy-cpp 2>/dev/null || \
        echo "WARNING: ananicy-cpp unavailable; continuing without daemon"
fi

# scx_lavd is provided by scx-scheds-git (not a separate package). Create the systemd service for it.
# If scx_lavd binary isn't found, scheduler fallback to scx_loader invocation is used.

# Version lock so dnf updates never pull stock Fedora kernel
dnf5 versionlock add kernel-cachyos-lto kernel-cachyos-lto-devel-matched

echo "CachyOS kernel installed: $(rpm -q kernel-cachyos-lto)"

# Mask zram services (Ryven uses zswap)
systemctl mask --no-reload systemd-zram-setup@zram0.service dev-zram0.swap zram-swap.service 2>/dev/null || true
