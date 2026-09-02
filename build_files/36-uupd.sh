#!/bin/bash
# uupd from Terra (ublue COPR fallback). Timer stages updates; never reboot.

set -ouex pipefail
# shellcheck source=copr-helpers.sh
source /ctx/copr-helpers.sh

dnf5 -y install --enablerepo=terra --skip-unavailable uupd || \
  copr_install_isolated "ublue-os/packages" uupd || true

dnf5 -y install --skip-unavailable topgrade || true

if [[ -f /etc/rpm-ostreed.conf ]]; then
  sed -i 's/^AutomaticUpdatePolicy=.*/AutomaticUpdatePolicy=none/' /etc/rpm-ostreed.conf || true
fi

systemctl enable uupd.timer || true
