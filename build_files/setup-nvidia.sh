#!/usr/bin/env bash
# Enable RPMFusion/Terra-nvidia, install NVIDIA open driver stack, configure services.
set -euo pipefail

KERNEL_VERSION="$(rpm -q kernel-cachyos-lto --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | head -n1)"

echo "Installing RPMFusion (required for NVIDIA open kmods)..."
dnf5 install -y --skip-unavailable \
    "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
    "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" \
    "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-tainted-release-$(rpm -E %fedora).noarch.rpm"

echo "Enabling Terra (nvidia-vaapi, mesa, codecs)..."
dnf5 -y install --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra'"$(rpm -E %fedora)" terra-release terra-gpg-keys
dnf5 config-manager --set-enabled terra-mesa terra-extras terra-nvidia
# Terra higher priority than RPMFusion for codec/mesa packages
dnf5 config-manager --setopt=terra.priority=50 --save
dnf5 config-manager --setopt=terra-mesa.priority=40 --save

echo "Installing NVIDIA open kernel driver + userspace..."
dnf5 install -y --skip-unavailable \
    akmod-nvidia nvidia-driver nvidia-driver-libs nvidia-driver-cuda \
    nvidia-driver-libs.i686 nvidia-driver-cuda.i686 \
    nvidia-gpu-firmware nvidia-modprobe nvidia-persistenced nvidia-settings \
    nvidia-vaapi-driver libva-utils vdpauinfo nv-codec-headers \
    mesa-vaapi-drivers mesa-vdpau-drivers

echo "Installing third-party akmods..."
dnf5 copr enable -y atim/xone
dnf5 install -y --skip-unavailable xone akmod-xone xpadneo akmod-xpadneo openrazer akmod-openrazer

# Explicitly enable NVIDIA driver services (image contract, no first-boot detection)
systemctl enable --no-reload nvidia-persistenced.service
systemctl enable --no-reload nvidia-suspend.service
systemctl enable --no-reload nvidia-hibernate.service
systemctl enable --no-reload nvidia-resume.service

# Coolbits 28 (overclock/fan control) via modprobe.d
cat > /etc/modprobe.d/nvidia-coolbits.conf <<'EOF'
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_EnableGpuFirmware=1 NVreg_EnableResizableBar=1 Coolbits=28
EOF

echo "NVIDIA stack installed for kernel ${KERNEL_VERSION}"
