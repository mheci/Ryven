#!/bin/bash
# Zed editor from Terra (Fedora 44).

set -ouex pipefail

dnf5 -y install --enablerepo=terra zed
