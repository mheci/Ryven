#!/bin/bash
# Zen Browser from isolated COPR sneexy/zen-browser (Fedora 44).

set -ouex pipefail
# shellcheck source=copr-helpers.sh
source /ctx/copr-helpers.sh

copr_install_isolated "sneexy/zen-browser" zen-browser
