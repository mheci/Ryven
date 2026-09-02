#!/bin/bash
# Terra-first Mesa, ffmpeg/GStreamer, thumbnails, NVIDIA VA-API.
# Never swap RPM Fusion mesa-*-freeworld (removes nvidia-driver).
# Never enable terra-nvidia.

set -ouex pipefail

TERRA=(--enablerepo=terra,terra-mesa,terra-multimedia)
FUSION=(--enablerepo=rpmfusion-free,rpmfusion-free-updates,rpmfusion-nonfree,rpmfusion-nonfree-updates)

if ! dnf5 -y distro-sync "${TERRA[@]}" \
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
  echo "Terra Mesa distro-sync failed (likely NVIDIA userspace file conflict). Keeping current Mesa." >&2
fi

if rpm -q ffmpeg-free >/dev/null 2>&1 && ! rpm -q ffmpeg >/dev/null 2>&1; then
  dnf5 -y swap "${TERRA[@]}" --allowerasing ffmpeg-free ffmpeg || \
    dnf5 -y swap "${FUSION[@]}" --allowerasing ffmpeg-free ffmpeg
fi
if ! rpm -q ffmpeg >/dev/null 2>&1; then
  dnf5 -y install "${TERRA[@]}" ffmpeg || dnf5 -y install "${FUSION[@]}" ffmpeg
fi

dnf5 -y install "${TERRA[@]}" "${FUSION[@]}" \
  libva-nvidia-driver.x86_64 \
  libva-nvidia-driver.i686 \
  libva \
  libva-utils \
  libvdpau \
  vdpauinfo \
  gstreamer1-plugin-libav \
  gstreamer1-plugin-openh264 \
  gstreamer1-vaapi \
  mozilla-openh264 \
  dav1d \
  aom \
  svt-av1 \
  lame \
  opus \
  ffmpegthumbnailer

dnf5 -y install "${TERRA[@]}" "${FUSION[@]}" \
  intel-media-driver \
  libva-intel-driver \
  gstreamer1-plugins-ugly \
  x264 \
  totem-video-thumbnailer \
  kdegraphics-thumbnailers \
  icoextract-thumbnailer \
  python3-icoextract

dnf5 -y install --enablerepo=rpmfusion-free "${FUSION[@]}" rpmfusion-free-release-tainted
dnf5 -y install --enablerepo=rpmfusion-free-tainted libdvdcss
shopt -s nullglob
for repo in /etc/yum.repos.d/*tainted*.repo; do
  sed -i 's/^enabled=1/enabled=0/' "${repo}"
done
