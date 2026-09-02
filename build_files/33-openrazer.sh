#!/bin/bash
# OpenRazer userspace from Terra. polychromatic from Fedora, else official razer repo.

set -ouex pipefail

# shellcheck source=copr-helpers.sh
source /ctx/copr-helpers.sh

dnf5 -y install --enablerepo=terra openrazer-daemon python3-openrazer
getent group plugdev >/dev/null || groupadd -r plugdev

if ! dnf5 -y install polychromatic; then
  dnf5 -y config-manager addrepo --from-repofile=https://openrazer.github.io/hardware:razer.repo --overwrite
  dnf5 -y install polychromatic
  shopt -s nullglob
  for repo in /etc/yum.repos.d/*razer*.repo; do
    sed -i 's/^enabled=1/enabled=0/' "${repo}"
  done
fi
