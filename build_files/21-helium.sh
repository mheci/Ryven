#!/bin/bash
# Helium Browser native RPM from Terra (Fedora 44).

set -ouex pipefail

dnf5 -y install --enablerepo=terra helium-browser-bin
