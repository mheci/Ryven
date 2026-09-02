#!/bin/bash
# Terra f44 Name: uupd. topgrade: Fedora.

set -ouex pipefail
# shellcheck source=repo-priority.sh
source /ctx/repo-priority.sh

install_priority uupd
install_priority topgrade

if [[ -f /etc/rpm-ostreed.conf ]]; then
  if grep -q '^AutomaticUpdatePolicy=' /etc/rpm-ostreed.conf; then
    sed -i 's/^AutomaticUpdatePolicy=.*/AutomaticUpdatePolicy=none/' /etc/rpm-ostreed.conf
  fi
fi

systemctl enable uupd.timer
