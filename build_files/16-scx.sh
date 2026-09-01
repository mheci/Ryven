#!/bin/bash
# sched-ext userspace (scx-scheds) from CachyOS addons COPR, Fedora 44.
# Do not enable scx-loader at boot; ujust will select a scheduler later.

set -ouex pipefail
# shellcheck source=copr-helpers.sh
source /ctx/copr-helpers.sh

copr_install_isolated "bieszczaders/kernel-cachyos-addons" scx-scheds
