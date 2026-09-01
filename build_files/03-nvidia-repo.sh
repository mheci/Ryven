#!/bin/bash
# NVIDIA network repository for Fedora 44 (x86_64), official cuda-fedora44.repo.
# Does not install nvidia-open; that is a later commit.

set -ouex pipefail

FEDORA_RELEASE=44
ARCH=x86_64
REPO_URL="https://developer.download.nvidia.com/compute/cuda/repos/fedora${FEDORA_RELEASE}/${ARCH}/cuda-fedora${FEDORA_RELEASE}.repo"

dnf5 -y install dnf5-plugins
dnf5 -y config-manager addrepo --from-repofile="${REPO_URL}"
dnf5 clean expire-cache
