#!/bin/bash
# uupd from Terra, then ublue COPR. Timer stages updates; never reboot.

set -ouex pipefail
# shellcheck source=copr-helpers.sh
source /ctx/copr-helpers.sh

if ! dnf5 -y install --enablerepo=terra uupd; then
  copr_install_isolated "ublue-os/packages" uupd
fi

dnf5 -y install topgrade

if [[ -f /etc/rpm-ostreed.conf ]]; then
  if grep -q '^AutomaticUpdatePolicy=' /etc/rpm-ostreed.conf; then
    sed -i 's/^AutomaticUpdatePolicy=.*/AutomaticUpdatePolicy=none/' /etc/rpm-ostreed.conf
  fi
fi

systemctl enable uupd.timer
