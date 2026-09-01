#!/bin/bash
# Leave third-party repo files in place but disabled on the running image.
# Build scripts re-enable them with --enablerepo when installing packages.

set -ouex pipefail

shopt -s nullglob
for repo in /etc/yum.repos.d/rpmfusion*.repo \
            /etc/yum.repos.d/*terra*.repo \
            /etc/yum.repos.d/cuda*.repo \
            /etc/yum.repos.d/*nvidia*.repo; do
  sed -i 's/^enabled=1/enabled=0/' "${repo}"
done
