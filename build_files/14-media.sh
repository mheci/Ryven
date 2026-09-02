#!/bin/bash
# Terra/Fedora mpv (stable), Terra yt-dlp-git, python-yt-dlp-ejs, ffmpeg. Fusion ffmpeg fallback.

set -ouex pipefail
# shellcheck source=repo-priority.sh
source /ctx/repo-priority.sh

install_priority mpv yt-dlp-git python-yt-dlp-ejs
swap_ffmpeg_priority
