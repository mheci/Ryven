#!/bin/bash
# greenboot health checks for bootc.

set -ouex pipefail

dnf5 -y install greenboot greenboot-default-health-checks

enabled=0
shopt -s nullglob
for unit in /usr/lib/systemd/system/greenboot*.service \
            /usr/lib/systemd/system/redboot*.service; do
  systemctl enable "$(basename "${unit}")"
  enabled=1
done
if [[ ${enabled} -eq 0 ]]; then
  echo "greenboot installed but no units under /usr/lib/systemd/system" >&2
  rpm -ql greenboot | head -40 >&2
  exit 1
fi
