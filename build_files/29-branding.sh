#!/bin/bash
# Identify as Ryven on bootc, GRUB, Plymouth, and Plasma Global Theme.

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

# Prefer Ryven look-and-feel over Fedora/Breeze for first login.
if [[ -d /usr/share/plasma/look-and-feel/org.ryven.desktop ]]; then
  mkdir -p /etc/xdg
  if [[ -f /usr/libexec/plasma-set-default-lookandfeel ]]; then
    /usr/libexec/plasma-set-default-lookandfeel org.ryven.desktop || true
  fi
fi
