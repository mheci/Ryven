#!/bin/bash
# Fedora 44 Terra (Fyra Labs) release metadata.
# Bootstrap uses --nogpgcheck only long enough to install terra-release,
# which ships the signing keys. No Terra payload packages here.

set -ouex pipefail

FEDORA_RELEASE=44

dnf5 -y install --nogpgcheck \
  --repofrompath "terra,https://repos.fyralabs.com/terra${FEDORA_RELEASE}" \
  terra-release
