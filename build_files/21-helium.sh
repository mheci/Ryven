#!/bin/bash
# Helium Browser native RPM from Terra (Fedora 44).

set -ouex pipefail

# Binary RPMs unpack under /opt; ostree may not have a real directory there.
if [ -L /opt ] || [ ! -d /opt ]; then
  rm -f /opt
  mkdir -p /opt
fi

dnf5 -y install --enablerepo=terra helium-browser-bin
