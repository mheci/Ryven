#!/bin/bash
# Helium Browser: Terra Name helium-browser-bin (anda/apps/helium-browser-bin).

set -ouex pipefail

dnf5 -y install --enablerepo=terra helium-browser-bin
