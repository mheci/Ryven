#!/bin/bash
# ffmpeg (also 23-codecs), yt-dlp, mpv from Terra, Fusion fallback.

set -ouex pipefail

TERRA=(--enablerepo=terra,terra-multimedia)
FUSION=(--enablerepo=rpmfusion-free,rpmfusion-nonfree)

dnf5 -y install --skip-unavailable "${TERRA[@]}" \
  mpv \
  yt-dlp \
  yt-dlp-ejs \
  ffmpeg || \
dnf5 -y install --skip-unavailable "${FUSION[@]}" \
  mpv \
  yt-dlp \
  ffmpeg
