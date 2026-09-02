#!/bin/bash
# OpenRazer userspace from Terra (kmod from ublue akmods). polychromatic is not Terra f44.

set -ouex pipefail

dnf5 -y install --enablerepo=terra openrazer-daemon python3-openrazer
getent group plugdev >/dev/null || groupadd -r plugdev
