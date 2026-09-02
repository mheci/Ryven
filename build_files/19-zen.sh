#!/bin/bash
# Zen Browser: not on Terra f44. Official COPR sneexy/zen-browser after Terra/Fusion/Fedora miss.

set -ouex pipefail
# shellcheck source=repo-priority.sh
source /ctx/repo-priority.sh
# shellcheck source=copr-helpers.sh
source /ctx/copr-helpers.sh

if ! install_any zen-browser; then
  copr_install_isolated "sneexy/zen-browser" zen-browser
fi
