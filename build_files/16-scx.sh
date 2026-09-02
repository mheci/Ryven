#!/bin/bash
# sched-ext userspace from Terra. Do not enable scx at boot.

set -ouex pipefail

dnf5 -y install --enablerepo=terra --skip-unavailable --skip-broken \
  scx-scheds \
  scx-tools || true
