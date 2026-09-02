#!/bin/bash
# mpv-nightly, yt-dlp-git, python-yt-dlp-ejs, ffmpeg from Terra f44 (verified Name:).

set -ouex pipefail

TERRA=(--enablerepo=terra,terra-multimedia)
FUSION=(--enablerepo=rpmfusion-free,rpmfusion-nonfree)

dnf5 -y install "${TERRA[@]}" mpv-nightly yt-dlp-git python-yt-dlp-ejs

if rpm -q ffmpeg-free >/dev/null 2>&1 && ! rpm -q ffmpeg >/dev/null 2>&1; then
  if ! dnf5 -y swap "${TERRA[@]}" --allowerasing ffmpeg-free ffmpeg; then
    dnf5 -y swap "${FUSION[@]}" --allowerasing ffmpeg-free ffmpeg
  fi
fi
if ! rpm -q ffmpeg >/dev/null 2>&1; then
  if ! dnf5 -y install "${TERRA[@]}" ffmpeg; then
    dnf5 -y install "${FUSION[@]}" ffmpeg
  fi
fi
