#!/bin/bash
# Brave Browser from Brave's signed Fedora RPM repo (Fedora 44).
# Package name remains brave-browser (Origin branding).

set -ouex pipefail

cat >/etc/yum.repos.d/brave-browser.repo <<'EOF'
[brave-browser]
name=Brave Browser
baseurl=https://brave-browser-rpm-release.s3.brave.com/x86_64
enabled=0
gpgcheck=1
gpgkey=https://brave-browser-rpm-release.s3.brave.com/brave-core.asc
EOF

dnf5 -y install --enablerepo=brave-browser brave-browser
