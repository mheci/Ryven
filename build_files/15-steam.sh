#!/bin/bash
# Steam: Terra Name: steam, then RPM Fusion nonfree, then Fedora.

set -ouex pipefail
# shellcheck source=repo-priority.sh
source /ctx/repo-priority.sh

install_priority steam
