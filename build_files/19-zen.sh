#!/bin/bash
# Zen Browser from isolated COPR sneexy/zen-browser (Fedora 44).

set -ouex pipefail
# shellcheck source=copr-helpers.sh
source /ctx/copr-helpers.sh

# RPM unpacks into /opt/zen. On ostree/bootc, /opt may be a non-directory
# placeholder; make it a real directory before the transaction.
if [ -L /opt ] || [ ! -d /opt ]; then
  rm -f /opt
  mkdir -p /opt
fi

copr_install_isolated "sneexy/zen-browser" zen-browser
