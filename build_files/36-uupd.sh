#!/bin/bash
# uupd + topgrade. Timer stages updates; never reboot the host.

set -ouex pipefail
# shellcheck source=copr-helpers.sh
source /ctx/copr-helpers.sh

copr_install_isolated "ublue-os/packages" uupd || \
  dnf5 -y install --enablerepo=terra --skip-unavailable uupd || true

dnf5 -y install --skip-unavailable topgrade || true

if [[ -f /etc/rpm-ostreed.conf ]]; then
  sed -i 's/^AutomaticUpdatePolicy=.*/AutomaticUpdatePolicy=none/' /etc/rpm-ostreed.conf || true
fi

systemctl enable uupd.timer || true
