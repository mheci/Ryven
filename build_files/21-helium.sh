#!/bin/bash
# Helium: Terra Name helium-browser-bin exists on frawhide; try Terra f44 then Fedora.

set -ouex pipefail
# shellcheck source=repo-priority.sh
source /ctx/repo-priority.sh

install_any helium-browser-bin helium-browser
