#!/usr/bin/env bash
# Build all required akmods against the currently installed CachyOS-LTO kernel.
# Must run AFTER kernel-cachyos-lto is installed and akmods-ostree-post is patched.
set -euo pipefail

KERNEL_VERSION="$(rpm -q kernel-cachyos-lto --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | head -n1)"
echo "Building akmods for kernel: ${KERNEL_VERSION}"

# Ensure kernel-devel-matched is installed (required for kmod builds)
if ! rpm -q "kernel-cachyos-lto-devel-matched" &>/dev/null; then
    dnf5 install -y --skip-unavailable kernel-cachyos-lto-devel-matched
fi

# Generate signing key if missing (akmods signs built modules)
if [ ! -f /etc/pki/akmods/certs/public_key.der ]; then
    kmodgenca -a --force
fi

# Build all required kmods
akmods --kernels "${KERNEL_VERSION}" --akmod nvidia
akmods --kernels "${KERNEL_VERSION}" --akmod xone
akmods --kernels "${KERNEL_VERSION}" --akmod xpadneo
akmods --kernels "${KERNEL_VERSION}" --akmod openrazer

# Verify builds succeeded
for mod in nvidia xone xpadneo openrazer; do
    if ! ls "/usr/lib/modules/${KERNEL_VERSION}/extra/${mod}"*.ko* >/dev/null 2>&1; then
        echo "ERROR: kmod ${mod} failed to build for ${KERNEL_VERSION}" >&2
        exit 1
    fi
done

# Run depmod for target kernel
depmod -a "${KERNEL_VERSION}"
echo "All akmods built successfully for ${KERNEL_VERSION}"
