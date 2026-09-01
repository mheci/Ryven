#!/bin/bash
# Identify as Ryven on bootc, GRUB, and Plymouth watermark.

set -ouex pipefail

if [[ -f /usr/lib/os-release ]]; then
  sed -i \
    -e 's/^NAME=.*/NAME="Ryven"/' \
    -e 's/^PRETTY_NAME=.*/PRETTY_NAME="Ryven (Fedora Kinoite)"/' \
    /usr/lib/os-release
  if grep -q '^IMAGE_ID=' /usr/lib/os-release; then
    sed -i 's/^IMAGE_ID=.*/IMAGE_ID="ryven"/' /usr/lib/os-release
  else
    echo 'IMAGE_ID="ryven"' >>/usr/lib/os-release
  fi
fi

mkdir -p /etc/default/grub.d
cat >/etc/default/grub.d/50-ryven.cfg <<'EOF'
GRUB_DISTRIBUTOR="Ryven"
EOF

if [[ -d /usr/share/plymouth/themes/spinner ]]; then
  cp -f /usr/share/pixmaps/ryven.png /usr/share/plymouth/themes/spinner/watermark.png || true
fi
