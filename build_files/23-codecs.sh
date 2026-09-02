#!/bin/bash
# Terra-first Mesa (codec-complete), ffmpeg/GStreamer, thumbnails, NVIDIA VA-API.
# Never swap RPM Fusion mesa-*-freeworld (removes nvidia-driver).
# Never enable terra-nvidia (Negativo17 CUDA/drivers).

set -ouex pipefail

TERRA=(--enablerepo=terra,terra-mesa,terra-multimedia)
FUSION=(--enablerepo=rpmfusion-free,rpmfusion-free-updates,rpmfusion-nonfree,rpmfusion-nonfree-updates)

# Terra Mesa stream (priority 80). Abort if the transaction would drop NVIDIA userspace.
if ! dnf5 -y distro-sync --skip-unavailable "${TERRA[@]}" \
  mesa-dri-drivers \
  mesa-va-drivers \
  mesa-vulkan-drivers \
  mesa-libGL \
  mesa-libEGL \
  mesa-libgbm \
  mesa-filesystem \
  mesa-dri-drivers.i686 \
  mesa-va-drivers.i686 \
  mesa-vulkan-drivers.i686 \
  mesa-libGL.i686 \
  mesa-libEGL.i686 \
  mesa-libgbm.i686; then
  echo "WARN: Terra Mesa distro-sync skipped (NVIDIA/Mesa conflict or missing pkgs)"
fi

if rpm -q ffmpeg-free >/dev/null 2>&1; then
  dnf5 -y swap "${TERRA[@]}" --allowerasing ffmpeg-free ffmpeg \
    || dnf5 -y swap "${FUSION[@]}" --allowerasing ffmpeg-free ffmpeg \
    || true
fi
dnf5 -y install --skip-unavailable "${TERRA[@]}" ffmpeg \
  || dnf5 -y install --skip-unavailable "${FUSION[@]}" ffmpeg \
  || true

# Skip Fusion x265 / gstreamer1-plugins-bad-freeworld (libx265.so.215 vs x265-libs 4.2).
# Skip pipewire-codec-aptx (conflicts pipewire-libs-extra).
# Skip ffmpegthumbs (pulls KDE Frameworks); use ffmpegthumbnailer.
# NVIDIA HVA: libva-nvidia-driver (Fedora), not terra-nvidia kmods.
# Mesa VA/VDPAU comes from terra-mesa above, not Fusion freeworld.
dnf5 -y install --skip-unavailable --skip-broken "${TERRA[@]}" "${FUSION[@]}" \
  libva-nvidia-driver.x86_64 \
  libva-nvidia-driver.i686 \
  intel-media-driver \
  libva-intel-driver \
  libva \
  libva-utils \
  libvdpau \
  vdpauinfo \
  gstreamer1-plugins-ugly \
  gstreamer1-plugin-libav \
  gstreamer1-plugin-openh264 \
  gstreamer1-vaapi \
  mozilla-openh264 \
  x264 \
  dav1d \
  aom \
  svt-av1 \
  lame \
  opus \
  ffmpegthumbnailer \
  totem-video-thumbnailer \
  kdegraphics-thumbnailers \
  icoextract-thumbnailer \
  python3-icoextract || true

dnf5 -y install "${FUSION[@]}" rpmfusion-free-release-tainted || true
dnf5 -y install --enablerepo=rpmfusion-free-tainted libdvdcss || true
shopt -s nullglob
for repo in /etc/yum.repos.d/*tainted*.repo; do
  sed -i 's/^enabled=1/enabled=0/' "${repo}"
done
