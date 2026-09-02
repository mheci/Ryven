#!/bin/bash
# MangoHud + OBS VkCapture: Fedora, Fusion if needed.

set -ouex pipefail
# shellcheck source=repo-priority.sh
source /ctx/repo-priority.sh

install_priority mangohud obs-vkcapture

if dnf5 list --available --enablerepo="${TERRA_REPOS}" --enablerepo="${FUSION_REPOS}" mangohud.i686 >/dev/null 2>&1; then
  install_priority mangohud.i686
fi
if dnf5 list --available --enablerepo="${TERRA_REPOS}" --enablerepo="${FUSION_REPOS}" obs-vkcapture.i686 >/dev/null 2>&1; then
  install_priority obs-vkcapture.i686
fi
install_any goverlay
