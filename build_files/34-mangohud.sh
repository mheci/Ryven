#!/bin/bash
# MangoHud + OBS VkCapture (64-bit and 32-bit when available).

set -ouex pipefail

dnf5 -y install --skip-unavailable --skip-broken \
  mangohud \
  mangohud.i686 \
  goverlay \
  obs-vkcapture \
  obs-vkcapture.i686 \
  libobs_vkcapture \
  libobs_glcapture || true
