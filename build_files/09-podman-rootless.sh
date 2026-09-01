#!/bin/bash
# Rootless Podman only. Do not create or populate a docker group.

set -ouex pipefail

dnf5 -y install podman podman-compose

if rpm -q docker-ce >/dev/null 2>&1 || rpm -q docker >/dev/null 2>&1; then
  echo "docker RPM must not be present" >&2
  exit 1
fi

# Socket for rootless/user workflows; no docker.socket.
systemctl enable podman.socket
