#!/bin/bash
# Fedora 44 Terra (Fyra Labs) release metadata.
# Bootstrap uses --nogpgcheck only long enough to install terra-release,
# which ships the signing keys. Subrepos: mesa + multimedia (F43+).
# Do not install terra-release-nvidia: NVIDIA kmods stay ublue akmods.

set -ouex pipefail

FEDORA_RELEASE=44

dnf5 -y install --nogpgcheck \
  --repofrompath "terra,https://repos.fyralabs.com/terra${FEDORA_RELEASE}" \
  terra-release

dnf5 -y install --enablerepo=terra \
  terra-release-mesa \
  terra-release-multimedia
