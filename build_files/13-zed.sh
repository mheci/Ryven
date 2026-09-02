#!/bin/bash
# Zed: Terra stable (Name: zed).

set -ouex pipefail
# shellcheck source=repo-priority.sh
source /ctx/repo-priority.sh

install_priority zed
