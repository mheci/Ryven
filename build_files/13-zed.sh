#!/bin/bash
# Zed nightly from Terra f44 (Name: zed-nightly).

set -ouex pipefail

dnf5 -y install --enablerepo=terra zed-nightly
