#!/bin/bash
# Brave Origin from Brave's signed Fedora RPM repo (Fedora 44).
# Official package: brave-origin (not brave-browser).

set -ouex pipefail

cat >/etc/yum.repos.d/brave-browser.repo <<'EOF'
[brave-browser]
name=Brave Browser
baseurl=https://brave-browser-rpm-release.s3.brave.com/$basearch
enabled=0
gpgcheck=1
gpgkey=https://brave-browser-rpm-release.s3.brave.com/brave-core.asc
EOF

dnf5 -y install --enablerepo=brave-browser brave-origin
