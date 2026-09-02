#!/bin/bash
# Terra f44: scx-scheds-nightly + scx-tools-nightly (scx_loader). lavd max performance.

set -ouex pipefail
# shellcheck source=repo-priority.sh
source /ctx/repo-priority.sh

install_priority scx-scheds-nightly scx-tools-nightly

mkdir -p /etc
cat >/etc/scx_loader.toml <<'EOF'
default_sched = "scx_lavd"
default_mode = "Gaming"

[scheds.scx_lavd]
auto_mode = ["--performance"]
gaming_mode = ["--performance"]
lowlatency_mode = ["--performance"]
powersave_mode = ["--performance"]
EOF

mkdir -p /etc/scx_loader
ln -sfn /etc/scx_loader.toml /etc/scx_loader/config.toml

mkdir -p /etc/default
if [[ ! -f /etc/default/scx ]]; then
  printf 'SCX_SCHEDULER=scx_lavd\nSCX_FLAGS=--performance\n' >/etc/default/scx
fi

if [[ ! -f /usr/lib/systemd/system/scx_loader.service ]]; then
  echo "scx-tools-nightly did not ship scx_loader.service" >&2
  rpm -ql scx-tools-nightly | head -80 >&2
  exit 1
fi
systemctl enable scx_loader.service
