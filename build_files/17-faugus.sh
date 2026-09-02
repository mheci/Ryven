#!/bin/bash
# Terra f44 Name: faugus-launcher.

set -ouex pipefail
# shellcheck source=repo-priority.sh
source /ctx/repo-priority.sh

install_priority faugus-launcher
