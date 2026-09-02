#!/bin/bash
# OpenRazer userspace from Terra (kmod already from ublue akmods).

set -ouex pipefail

dnf5 -y install --enablerepo=terra openrazer-daemon python3-openrazer
dnf5 -y install --enablerepo=terra polychromatic
getent group plugdev >/dev/null || groupadd -r plugdev
