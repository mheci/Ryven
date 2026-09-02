#!/bin/bash
# uupd from Terra f44 (Name: uupd). Timer stages updates; never reboot.

set -ouex pipefail

dnf5 -y install --enablerepo=terra uupd
dnf5 -y install topgrade

if [[ -f /etc/rpm-ostreed.conf ]]; then
  if grep -q '^AutomaticUpdatePolicy=' /etc/rpm-ostreed.conf; then
    sed -i 's/^AutomaticUpdatePolicy=.*/AutomaticUpdatePolicy=none/' /etc/rpm-ostreed.conf
  fi
fi

systemctl enable uupd.timer
