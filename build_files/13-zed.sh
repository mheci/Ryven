#!/bin/bash
# Zed: Terra zed-nightly (Name:), else Terra zed.

set -ouex pipefail
# shellcheck source=repo-priority.sh
source /ctx/repo-priority.sh

install_any zed-nightly zed
