#!/bin/bash
# faugus-launcher from Terra f44 (Name: faugus-launcher). No COPR.

set -ouex pipefail

dnf5 -y install --enablerepo=terra faugus-launcher
