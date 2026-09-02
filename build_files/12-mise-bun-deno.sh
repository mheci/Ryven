#!/bin/bash
# mise, bun, deno as native RPMs (Terra).

set -ouex pipefail

dnf5 -y install --enablerepo=terra mise bun deno
