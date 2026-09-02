#!/bin/bash
# OpenRazer userspace: Terra subpackages openrazer-daemon python3-openrazer.
# polychromatic: official OpenRazer repo, then Fedora.

set -ouex pipefail
# shellcheck source=repo-priority.sh
source /ctx/repo-priority.sh

install_priority openrazer-daemon python3-openrazer
getent group plugdev >/dev/null || groupadd -r plugdev

if ! dnf5 -y install polychromatic; then
  dnf5 -y config-manager addrepo --from-repofile=https://openrazer.github.io/hardware:razer.repo --overwrite
  dnf5 -y install polychromatic
  shopt -s nullglob
  for repo in /etc/yum.repos.d/*razer*.repo; do
    sed -i 's/^enabled=1/enabled=0/' "${repo}"
  done
fi
