#!/bin/bash
# sched-ext nightly from Terra. Default scx_lavd via /etc/default/scx.

set -ouex pipefail

dnf5 -y install --enablerepo=terra scx-scheds-nightly scx-tools

mkdir -p /etc/default
if [[ ! -f /etc/default/scx ]]; then
  printf 'SCX_SCHEDULER=scx_lavd\nSCX_FLAGS=\n' >/etc/default/scx
fi

if [[ -f /usr/lib/systemd/system/scx_loader.service ]]; then
  systemctl enable scx_loader.service
elif [[ -f /usr/lib/systemd/system/scx.service ]]; then
  systemctl enable scx.service
else
  echo "scx-scheds-nightly did not ship scx_loader.service or scx.service" >&2
  rpm -ql scx-scheds-nightly | head -80 >&2
  exit 1
fi
