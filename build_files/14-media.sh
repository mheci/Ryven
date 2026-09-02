#!/bin/bash
# mpv-nightly, yt-dlp, ffmpeg from Terra; Fusion only if Terra has no ffmpeg.

set -ouex pipefail

TERRA=(--enablerepo=terra,terra-multimedia)
FUSION=(--enablerepo=rpmfusion-free,rpmfusion-nonfree)

dnf5 -y install "${TERRA[@]}" mpv-nightly yt-dlp yt-dlp-ejs

if ! rpm -q ffmpeg >/dev/null 2>&1; then
  if rpm -q ffmpeg-free >/dev/null 2>&1; then
    dnf5 -y swap "${TERRA[@]}" --allowerasing ffmpeg-free ffmpeg || \
      dnf5 -y swap "${FUSION[@]}" --allowerasing ffmpeg-free ffmpeg
  else
    dnf5 -y install "${TERRA[@]}" ffmpeg || dnf5 -y install "${FUSION[@]}" ffmpeg
  fi
fi
