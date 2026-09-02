#!/bin/bash
# mise: Fedora if present, else official mise RPM repo (then disable).
# bun-bin + rust-deno: Terra f44.

set -ouex pipefail

if ! dnf5 -y install mise; then
  dnf5 -y config-manager addrepo --overwrite --from-repofile=https://mise.jdx.dev/rpm/mise.repo
  dnf5 -y install mise
  shopt -s nullglob
  for repo in /etc/yum.repos.d/*mise*.repo; do
    sed -i 's/^enabled=1/enabled=0/' "${repo}"
  done
fi

dnf5 -y install --enablerepo=terra bun-bin rust-deno
