#!/bin/bash
# OpenRazer userspace from Terra (kmod already from ublue akmods).

set -ouex pipefail

dnf5 -y install --enablerepo=terra --skip-unavailable --skip-broken \
  openrazer-daemon \
  python3-openrazer \
  python-openrazer \
  openrazer-meta \
  polychromatic \
  razergenie || true

groupadd -r plugdev || true
