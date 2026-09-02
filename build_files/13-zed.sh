#!/bin/bash
# Zed editor from Terra.

set -ouex pipefail

dnf5 -y install --enablerepo=terra zed
