#!/bin/bash

set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

### Repositories (Fedora 44)

/ctx/01-rpmfusion.sh
/ctx/02-terra.sh
/ctx/04-disable-third-party-repos.sh
/ctx/05-nvidia-open.sh
/ctx/06-nvidia-userspace.sh
/ctx/07-secureboot-tpm.sh
/ctx/08-chrony-nts.sh
/ctx/09-podman-rootless.sh
/ctx/10-firewall-sshd.sh
/ctx/11-git-gh-gcm.sh
/ctx/12-mise-bun-deno.sh
/ctx/13-zed.sh
/ctx/14-media.sh
/ctx/15-steam.sh
/ctx/16-scx.sh
/ctx/17-faugus.sh
/ctx/18-firefox.sh
/ctx/19-zen.sh
/ctx/20-brave.sh
/ctx/23-codecs.sh
/ctx/24-zram-off.sh
/ctx/25-plasma-login.sh
/ctx/26-greenboot.sh
/ctx/27-sudo-rs.sh
/ctx/28-fonts.sh
/ctx/29-branding.sh
/ctx/30-scopebuddy.sh
/ctx/32-bees.sh
/ctx/33-openrazer.sh
/ctx/34-mangohud.sh
/ctx/35-kyber.sh
/ctx/36-uupd.sh
/ctx/37-flatpaks.sh
/ctx/38-terra-stack.sh
/ctx/39-proton-cachyos.sh
/ctx/22-goss.sh

systemctl enable podman.socket
