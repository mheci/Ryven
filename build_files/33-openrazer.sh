#!/bin/bash
# OpenRazer userspace (kmod already from ublue akmods).

set -ouex pipefail

dnf5 -y install --skip-unavailable --skip-broken \
  openrazer-daemon \
  python3-openrazer \
  python-openrazer \
  openrazer-meta \
  polychromatic \
  razergenie || true

groupadd -r plugdev || true
