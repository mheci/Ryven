#!/bin/bash
# Fedora 44 RPM Fusion free + nonfree release metadata.
# No Fusion packages are installed here.

set -ouex pipefail

FEDORA_RELEASE=44

dnf5 -y install \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_RELEASE}.noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_RELEASE}.noarch.rpm"
