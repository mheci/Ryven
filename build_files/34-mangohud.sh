#!/bin/bash
# MangoHud + OBS VkCapture. 32-bit only if the repo actually has it.

set -ouex pipefail

dnf5 -y install mangohud obs-vkcapture

if dnf5 list --available mangohud.i686 >/dev/null 2>&1; then
  dnf5 -y install mangohud.i686
fi
if dnf5 list --available obs-vkcapture.i686 >/dev/null 2>&1; then
  dnf5 -y install obs-vkcapture.i686
fi
if dnf5 list --available goverlay >/dev/null 2>&1; then
  dnf5 -y install goverlay
fi
