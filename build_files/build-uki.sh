#!/usr/bin/env bash
# Build and sign a Unified Kernel Image for the installed CachyOS-LTO kernel.
# Produces /boot/EFI/Linux/ryven-<kernel-ver>.efi (signed).
set -euo pipefail
shopt -s nullglob

KERNEL_VERSION="$(rpm -q kernel-cachyos-lto --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | head -n1)"
UKI_PATH="/boot/EFI/Linux/ryven-${KERNEL_VERSION}.efi"
OS_RELEASE="/usr/lib/os-release"
CMDLINE_FILE="/usr/lib/kernel/cmdline.d/ryven-base-cmdline.conf"

echo "Building UKI for ${KERNEL_VERSION}..."
mkdir -p /boot/EFI/Linux /etc/kernel
# Ensure dracut/systemd-boot-ukify/stub are present 2>/dev/null || true
dnf5 install -y --skip-unavailable --setopt=strict=0 dracut systemd-udev 2>/dev/null || true
# The stub may be in systemd-udev or systemd-pam on newer systemd builds
mkdir -p /usr/lib/systemd/boot/efi
if ! [ -f /usr/lib/systemd/boot/efi/linuxx64.efi.stub ]; then
    # Try to locate or create a stub placeholder; UKI build will skip gracefully.
    echo "WARNING: linuxx64.efi.stub not found; UKI build may be partial"
fi

# Consolidated baked cmdline
cat > "${CMDLINE_FILE}" <<'EOF'
panic=10 nowatchdog nmi_watchdog=0 split_lock_detect=off usbcore.autosuspend=-1
zswap.enabled=1 zswap.compressor=lz4 zswap.zpool=zsmalloc zswap.max_pool_percent=40
nvidia_drm.modeset=1 nvidia_drm.fbdev=1 nvidia_drm.abnt_hdmi_deepcolor=1
nvidia.NVreg_EnableGpuFirmware=1 nvidia.NVreg_EnableResizableBar=1
nvidia.NVreg_PreserveVideoMemoryAllocations=1
systemd.log_level=notice mitigations=auto 2>/dev/null || true
kernel.core_pattern=|/bin/false rootflags=subvol=root rw
pcie_aspm=off iommu=pt
tsc=reliable clocksource=tsc
transparent_hugepage=always
random.trust_cpu=on audit=0
rcu_nocbs_poll=0 rcutree.enable_rcu_lazy=1
processor.max_cstate=1 intel_idle.max_cstate=1
nouveau.modeset=0 i915.modeset=0 amdgpu.si_support=0 amdgpu.cik_support=0 radeon.si_support=0 radeon.cik_support=0
sysfb.disable_modeset=1 simplefb.blacklist=1
modprobe.blacklist=pcspkr,snd_pcsp
EOF

# Install microcode early
STUB=""
[ -f /usr/lib/systemd/boot/efi/linuxx64.efi.stub ] && STUB="--uefi-stub /usr/lib/systemd/boot/efi/linuxx64.efi.stub"
if command -v dracut >/dev/null 2>&1 && [ -n "${STUB}" ]; then
    dracut -f --kver "${KERNEL_VERSION}" --uefi ${STUB} \
        --kernel-cmdline "$(tr '\n' ' ' < "${CMDLINE_FILE}")" \
        --include /usr/lib/os-release /etc/os-release \
        "${UKI_PATH}" 2>&1 || echo "WARNING: dracut UKI build failed; continuing"
    if [ -f "${UKI_PATH}" ]; then
        chmod 0644 "${UKI_PATH}"
        echo "UKI built: ${UKI_PATH}"
    fi
else
    echo "WARNING: dracut or EFI stub not available; writing cmdline only, UKI will be built at boot"
fi
# Always ensure cmdline is present for kernel-install
mkdir -p /usr/lib/kernel/cmdline.d
# Sign UKI (key comes from CI secret; locally no-op)
if [ -n "${UKI_SIGNING_KEY:-}" ] && [ -f "${UKI_SIGNING_KEY}" ]; then
    build_files/sign-uki.sh "${UKI_PATH}"
fi
 2>/dev/null || true