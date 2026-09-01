#!/bin/bash
# faugus-launcher from isolated COPR (Fedora 44).
# proton-cachyos has no Fedora 44 RPM; skip (no curl installers).

set -ouex pipefail
# shellcheck source=copr-helpers.sh
source /ctx/copr-helpers.sh

copr_install_isolated "faugus/faugus-launcher" faugus-launcher
