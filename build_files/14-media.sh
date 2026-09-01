#!/bin/bash
# ffmpeg, yt-dlp, mpv from RPM Fusion / Fedora (Fedora 44).

set -ouex pipefail

dnf5 -y install --enablerepo=rpmfusion-free,rpmfusion-nonfree \
  ffmpeg \
  yt-dlp \
  mpv
