#!/bin/bash
# mise, bun, deno as native RPMs (Terra F44, then Fedora).

set -ouex pipefail

dnf5 -y install --enablerepo=terra --skip-unavailable --skip-broken \
  mise bun deno
