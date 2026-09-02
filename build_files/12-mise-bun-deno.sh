#!/bin/bash
# mise: Fedora. bun-bin + rust-deno: Terra f44 (verified Name:).

set -ouex pipefail

dnf5 -y install mise
dnf5 -y install --enablerepo=terra bun-bin rust-deno
