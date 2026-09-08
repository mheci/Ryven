#!/usr/bin/env bash
# Basic retry helper for transient network failures
try() { for i in 1 2 3; do "$@" && return 0; echo "  retry $i/3 ($*)"; sleep 5; done; return 1; }
# Enable RPMFusion/Terra-nvidia, install NVIDIA open driver stack, configure services.
set -euo pipefail

KERNEL_VERSION="$(rpm -q kernel-cachyos-lto --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | head -n1)"

echo "Installing RPMFusion (required for NVIDIA open kmods)..."
dnf5 install -y --skip-unavailable \
    "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
    "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"

echo "Enabling Terra (nvidia-vaapi, mesa, codecs)..."
dnf5 -y install --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra'"$(rpm -E %fedora)" terra-release terra-gpg-keys
# dnf5 uses `enable` as a subcommand of config-manager
dnf5 config-manager enable terra-mesa terra-extras terra-nvidia 2>/dev/null || true
# Terra higher priority than RPMFusion for codec/mesa packages (dnf5 setopt)
dnf5 config-manager setopt terra.priority=50 terra-mesa.priority=40 --save 2>/dev/null || true

# Stub out akmods binary DURING RPM TRANSACTION so %post scriptlets of
# akmod-nvidia/-xone/-xpadneo/-openrazer don't fail trying to run auto-build
# as root in a container. Create /usr/sbin/akmods as a no-op BEFORE the
# packages are installed; RPM won't overwrite it since it matches (a file).
install -d -m 0755 /usr/sbin
cat > /usr/sbin/akmods <<'STUB'
#!/usr/bin/env bash
echo "akmods [container-build stub]: skipping auto-build; kmods will be built explicitly later" >&2
exit 0
STUB
chmod 0755 /usr/sbin/akmods
# Also set an env var telling akmods not to build (honored by akmods %post in some versions)
export DAKMODS_DISABLE_AUTO_BUILD=1
# Override RPM scriptlet failure so even if %post barfs, transaction completes
export RPM_SCRIPTLET_FAILURE_ACTION=warn

# Pre-create akmods user/group since tsflags=noscripts skips RPM sysusers.
getent group akmods >/dev/null || groupadd -r akmods
id akmods >/dev/null 2>&1 || useradd -r -g akmods -d /var/lib/akmods -s /sbin/nologin akmods
install -d -o akmods -g akmods -m 0755 /var/cache/akmods /var/lib/akmods

echo "Installing NVIDIA open kernel driver + userspace (auto-build stubbed)..."
dnf5 install -y --skip-unavailable --setopt=tsflags=noscripts \
    akmod-nvidia nvidia-driver nvidia-driver-libs nvidia-driver-cuda \
    nvidia-driver-libs.i686 nvidia-driver-cuda.i686 \
    nvidia-gpu-firmware nvidia-modprobe nvidia-persistenced nvidia-settings \
    nvidia-vaapi-driver libva-utils vdpauinfo nv-codec-headers \
    mesa-vaapi-drivers mesa-vdpau-drivers

echo "Installing third-party akmods..."
# xone (Xbox One dongle) — try atim/xone COPR; may not exist for new Fedora releases (404).
# Several repos (terra, fedora-multimedia, ublue-os/akmods) provide conflicting dkms-vs-akmod
# variants. Pick akmod from rpmfusion-free/updates primarily; --allowerasing + --skip-broken.
( dnf5 copr enable -y atim/xone 2>/dev/null && echo "atim/xone COPR enabled" ) \
    || echo "atim/xone COPR unavailable (404) for this Fedora release; trying RPMFusion"
# Disable repos that ship dkms-* conflicts for these packages during this install
dnf5 --setopt=terra.enabled=0 --setopt=fedora-multimedia.enabled=0 \
     install -y --skip-unavailable --allowerasing --setopt=tsflags=noscripts \
    xone akmod-xone xpadneo akmod-xpadneo openrazer akmod-openrazer \
    || dnf5 --setopt=terra.enabled=0 --setopt=fedora-multimedia.enabled=0 \
        install -y --skip-unavailable --allowerasing --skip-broken --setopt=tsflags=noscripts \
        xpadneo akmod-xpadneo openrazer akmod-openrazer \
        || echo "WARNING: some third-party akmods unavailable; continuing"

# Now restore the real akmods binary by reinstalling akmods (this time without
# noscripts, so its files replace our stub).
echo "Restoring real akmods binary..."
dnf5 reinstall -y akmods || dnf5 install -y akmods

# Explicitly enable NVIDIA driver services (image contract, no first-boot detection).
# Some services may not exist in all driver versions; fail soft.
for svc in nvidia-persistenced.service nvidia-suspend.service nvidia-hibernate.service nvidia-resume.service; do
    systemctl enable --no-reload "${svc}" 2>/dev/null || echo "WARNING: ${svc} not found; skipping enable"
done

# Coolbits 28 (overclock/fan control) via modprobe.d
cat > /etc/modprobe.d/nvidia-coolbits.conf <<'EOF'
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_EnableGpuFirmware=1 NVreg_EnableResizableBar=1 Coolbits=28
EOF

echo "NVIDIA stack installed for kernel ${KERNEL_VERSION}"
