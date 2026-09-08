#!/bin/sh
# Apply tunings that tuned sysctl/disk sections can't handle.
. /usr/lib/tuned/functions

start() {
    # Disable PCIe ASPM on all ports
    for dev in /sys/bus/pci/devices/*/power/control; do
        [ -w "$dev" ] && echo on > "$dev" 2>/dev/null || true
    done
    # Ensure sch_cake and tcp_bbr modules loaded
    modprobe sch_cake 2>/dev/null || true
    modprobe tcp_bbr 2>/dev/null || true
    # NVIDIA PowerMizer=1 (max performance) if nvidia-smi present
    if command -v nvidia-smi >/dev/null; then
        nvidia-smi -pm 1 >/dev/null 2>&1 || true
        nvidia-smi -pl "" >/dev/null 2>&1 || true
    fi
    # Set systemd journald log level
    echo "notice" > /proc/sys/kernel/printk 2>/dev/null || true
    return 0
}

stop() {
    return 0
}

process $@
