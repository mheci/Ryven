#!/usr/bin/env bash
# Runs once at first boot: writes CPU-specific kargs to /etc/kernel/cmdline.d/, adds user to groups.
# Idempotent (multiple runs produce the same state).
set -euo pipefail

MARKER="/etc/ryven-hardware.toml"
if [ -f "${MARKER}" ]; then
    echo "Hardware detection already ran, skipping."
    exit 0
fi

echo "Running Ryven first-boot hardware detection..."

# Detect CPU vendor and apply appropriate pstate kargs
CPU_VENDOR="$(awk '/vendor_id/{print $3; exit}' /proc/cpuinfo)"
mkdir -p /etc/kernel/cmdline.d

case "${CPU_VENDOR}" in
    AuthenticAMD)
        echo "Detected AMD CPU, enabling amd_pstate=active."
        echo "amd_pstate=active" > /etc/kernel/cmdline.d/50-ryven-amd.conf
        ;;
    GenuineIntel)
        echo "Detected Intel CPU."
        ;;
esac

# Add primary user to realtime/games groups if they exist
for user in $(getent passwd {1000..2000} | cut -d: -f1); do
    usermod -aG realtime,games "${user}" || true
done

# Scale min_free_kbytes for RAM < 32GB
TOTAL_MEM_KB="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
if [ "${TOTAL_MEM_KB}" -lt 33554432 ]; then
    echo "vm.min_free_kbytes = $((TOTAL_MEM_KB / 128))" > /usr/lib/sysctl.d/99-ryven-lowmem.conf
fi

cat > "${MARKER}" <<EOF
detected_at = "$(date -Iseconds)"
cpu_vendor = "${CPU_VENDOR}"
total_mem_kb = ${TOTAL_MEM_KB}
EOF

echo "Hardware detection complete."
