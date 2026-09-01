#!/bin/bash
# Fusion codecs, NVDEC/NVENC via libva-nvidia-driver, GStreamer, thumbnails.
# Do not swap mesa-*-freeworld: that removes nvidia-driver.

set -ouex pipefail

FUSION=(--enablerepo=rpmfusion-free,rpmfusion-free-updates,rpmfusion-nonfree,rpmfusion-nonfree-updates)

# fedora-multimedia already ships ffmpeg; swap is a no-op if so.
if rpm -q ffmpeg-free >/dev/null 2>&1; then
  dnf5 -y swap "${FUSION[@]}" --allowerasing ffmpeg-free ffmpeg || true
fi
dnf5 -y install --skip-unavailable "${FUSION[@]}" ffmpeg || true

# Skip Fusion x265 / gstreamer1-plugins-bad-freeworld: they need
# libx265.so.215 and conflict with fedora-multimedia x265-libs 4.2.
dnf5 -y install --skip-unavailable --skip-broken "${FUSION[@]}" \
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
  pipewire-codec-aptx \
  ffmpegthumbnailer \
  ffmpegthumbs

dnf5 -y install "${FUSION[@]}" rpmfusion-free-release-tainted || true
dnf5 -y install --enablerepo=rpmfusion-free-tainted libdvdcss || true
shopt -s nullglob
for repo in /etc/yum.repos.d/*tainted*.repo; do
  sed -i 's/^enabled=1/enabled=0/' "${repo}"
done
