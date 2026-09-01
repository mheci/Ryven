#!/bin/bash
# greenboot-rs (Fedora package name: greenboot) health checks for bootc.

set -ouex pipefail

dnf5 -y install greenboot greenboot-default-health-checks

systemctl enable greenboot-healthcheck.service || true
systemctl enable greenboot-task-runner.service || true
systemctl enable greenboot-status.service || true
systemctl enable greenboot-grub2-set-success.service || true
systemctl enable greenboot-grub2-set-counter.service || true
systemctl enable redboot-auto-reboot.service || true
systemctl enable redboot-task-runner.service || true
