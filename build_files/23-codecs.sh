#!/bin/bash
# Terra Mesa first (never mesa-*-freeworld). ffmpeg Terra then Fusion.
# Thumbnails: Terra icoextract-thumbnailer; python3-icoextract is Fedora.

set -ouex pipefail
# shellcheck source=repo-priority.sh
source /ctx/repo-priority.sh

if ! dnf5 -y distro-sync --enablerepo="${TERRA_REPOS}" \
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
  echo "Terra Mesa distro-sync failed (NVIDIA userspace conflict). Keeping current Mesa." >&2
fi

swap_ffmpeg_priority

install_priority \
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

if ! rpm -q libva-nvidia-driver >/dev/null 2>&1; then
  dnf5 -y install --enablerepo="${FUSION_REPOS}" \
    libva-nvidia-driver.x86_64 libva-nvidia-driver.i686
fi

install_priority \
  intel-media-driver \
  libva-intel-driver \
  gstreamer1-plugins-ugly \
  x264 \
  totem-video-thumbnailer \
  kdegraphics-thumbnailers \
  icoextract-thumbnailer

install_any python3-icoextract

dnf5 -y install --enablerepo=rpmfusion-free --enablerepo="${FUSION_REPOS}" rpmfusion-free-release-tainted
dnf5 -y install --enablerepo=rpmfusion-free-tainted libdvdcss
shopt -s nullglob
for repo in /etc/yum.repos.d/*tainted*.repo; do
  sed -i 's/^enabled=1/enabled=0/' "${repo}"
done
