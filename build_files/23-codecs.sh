#!/bin/bash
# Fusion/Terra codecs + GPU decoders (Fedora 44).
# Do not dnf swap mesa-*-freeworld: --allowerasing removes nvidia-driver.

set -ouex pipefail

FUSION=(--enablerepo=rpmfusion-free,rpmfusion-free-updates,rpmfusion-nonfree,rpmfusion-nonfree-updates)

dnf5 -y swap "${FUSION[@]}" --allowerasing ffmpeg-free ffmpeg || \
  dnf5 -y install "${FUSION[@]}" ffmpeg

dnf5 -y install "${FUSION[@]}" \
  intel-media-driver \
  libva-intel-driver \
  libva-nvidia-driver \
  libva-utils \
  libvdpau \
  vdpauinfo \
  gstreamer1-plugins-ugly \
  gstreamer1-plugins-bad-freeworld \
  gstreamer1-plugin-libav \
  gstreamer1-plugin-openh264 \
  mozilla-openh264 \
  x264 \
  x265 \
  dav1d \
  aom \
  svt-av1 \
  lame \
  opus \
  libva \
  pipewire-codec-aptx || \
dnf5 -y install "${FUSION[@]}" \
  libva-nvidia-driver \
  libva-utils \
  gstreamer1-plugin-libav \
  x264 \
  x265 \
  dav1d \
  lame \
  opus

dnf5 -y install "${FUSION[@]}" libva-nvidia-driver.i686 || true

dnf5 -y install rpmfusion-free-release-tainted
dnf5 -y install --enablerepo=rpmfusion-free-tainted libdvdcss || true
shopt -s nullglob
for repo in /etc/yum.repos.d/*tainted*.repo; do
  sed -i 's/^enabled=1/enabled=0/' "${repo}"
done
