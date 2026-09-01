#!/bin/bash
# Full Fusion/Terra codec stack + GPU VA-API/VDPAU (Fedora 44).
# Follows https://rpmfusion.org/Howto/Multimedia

set -ouex pipefail

FUSION=(--enablerepo=rpmfusion-free,rpmfusion-free-updates,rpmfusion-nonfree,rpmfusion-nonfree-updates)

# Full ffmpeg (replaces Fedora ffmpeg-free).
dnf5 -y swap "${FUSION[@]}" --allowerasing ffmpeg-free ffmpeg || \
  dnf5 -y install "${FUSION[@]}" ffmpeg

# Mesa hardware codecs (H.264/H.265) for AMD/Intel; 32-bit for Steam.
dnf5 -y swap "${FUSION[@]}" --allowerasing mesa-va-drivers mesa-va-drivers-freeworld || \
  dnf5 -y install "${FUSION[@]}" mesa-va-drivers-freeworld
dnf5 -y swap "${FUSION[@]}" --allowerasing mesa-vdpau-drivers mesa-vdpau-drivers-freeworld || \
  dnf5 -y install "${FUSION[@]}" mesa-vdpau-drivers-freeworld
dnf5 -y swap "${FUSION[@]}" --allowerasing mesa-vulkan-drivers mesa-vulkan-drivers-freeworld || true

dnf5 -y install "${FUSION[@]}" \
  mesa-va-drivers-freeworld.i686 \
  mesa-vdpau-drivers-freeworld.i686 \
  mesa-vulkan-drivers-freeworld.i686 || true

# Intel QSV (recent) + i965 (older); NVIDIA NVDEC via VA-API wrapper.
dnf5 -y install "${FUSION[@]}" \
  intel-media-driver \
  libva-intel-driver \
  libva-nvidia-driver \
  libva-nvidia-driver.i686 \
  libva-utils \
  libvdpau \
  libvdpau-va-gl \
  vdpauinfo || \
dnf5 -y install "${FUSION[@]}" \
  intel-media-driver \
  libva-intel-driver \
  libva-nvidia-driver \
  libva-utils \
  libvdpau \
  vdpauinfo

# GStreamer + browser/web codecs.
dnf5 -y install "${FUSION[@]}" \
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
  gstreamer1-plugins-ugly \
  gstreamer1-plugin-libav \
  x264 \
  x265 \
  dav1d \
  lame \
  opus

# DVD CSS from Fusion tainted-free (FLOSS, usage-restricted in some locales).
dnf5 -y install rpmfusion-free-release-tainted
dnf5 -y install --enablerepo=rpmfusion-free-tainted libdvdcss || true
shopt -s nullglob
for repo in /etc/yum.repos.d/*tainted*.repo; do
  sed -i 's/^enabled=1/enabled=0/' "${repo}"
done
