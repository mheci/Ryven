#!/bin/bash
# mise: official RPM repo (not in Fedora 44). bun-bin: Terra.
# rust-deno: Terra Name, else Fedora deno.

set -ouex pipefail

if ! dnf5 -y install mise; then
  dnf5 -y config-manager addrepo --overwrite --from-repofile=https://mise.jdx.dev/rpm/mise.repo
  dnf5 -y install mise
  shopt -s nullglob
  for repo in /etc/yum.repos.d/*mise*.repo; do
    sed -i 's/^enabled=1/enabled=0/' "${repo}"
  done
fi

dnf5 -y install --enablerepo=terra bun-bin

if ! dnf5 -y install --enablerepo=terra rust-deno; then
  if ! dnf5 -y install --enablerepo=terra deno; then
    dnf5 -y install deno
  fi
fi
