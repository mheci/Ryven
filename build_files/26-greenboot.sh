#!/bin/bash
# greenboot health checks for bootc.

set -ouex pipefail

dnf5 -y install greenboot greenboot-default-health-checks

enabled=0
for u in greenboot-healthcheck.service greenboot-task-runner.service \
  greenboot-status.service greenboot-grub2-set-success.service \
  greenboot-grub2-set-counter.service redboot-auto-reboot.service \
  redboot-task-runner.service; do
  if [[ -f /usr/lib/systemd/system/${u} ]]; then
    systemctl enable "${u}"
    enabled=1
  fi
done
if [[ ${enabled} -eq 0 ]]; then
  echo "greenboot installed but no units under /usr/lib/systemd/system" >&2
  rpm -ql greenboot | head -40 >&2
  exit 1
fi
