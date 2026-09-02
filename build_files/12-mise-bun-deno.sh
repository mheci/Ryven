#!/bin/bash
# mise: official jdx RPM repo (not in Fedora 44). bun-bin + rust-deno: Terra f44.

set -ouex pipefail
# shellcheck source=repo-priority.sh
source /ctx/repo-priority.sh

if ! dnf5 -y install mise; then
  dnf5 -y config-manager addrepo --overwrite --from-repofile=https://mise.jdx.dev/rpm/mise.repo
  dnf5 -y install mise
  shopt -s nullglob
  for repo in /etc/yum.repos.d/*mise*.repo; do
    sed -i 's/^enabled=1/enabled=0/' "${repo}"
  done
fi

install_priority bun-bin
install_any rust-deno deno
