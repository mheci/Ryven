#!/bin/bash
# Enable a COPR only for the listed packages, then disable it.

copr_install_isolated() {
  local copr=$1
  shift
  dnf5 -y copr enable "${copr}"
  dnf5 -y install "$@"
  dnf5 -y copr disable "${copr}"
}
