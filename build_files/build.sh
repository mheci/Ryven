#!/bin/bash

set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

### Repositories (Fedora 44)

/ctx/01-rpmfusion.sh
/ctx/02-terra.sh
/ctx/03-nvidia-repo.sh
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

### Install packages

# Packages can be installed from any enabled yum repo on the image.
# List of rpmfusion packages can be found here:
# https://mirrors.rpmfusion.org/mirrorlist?path=free/fedora/updates/44/x86_64/repoview/index.html&protocol=https&redirect=1

# Use a COPR Example:
#
# dnf5 -y copr enable ublue-os/staging
# dnf5 -y install package
# Disable COPRs so they don't end up enabled on the final image:
# dnf5 -y copr disable ublue-os/staging

#### Example for enabling a System Unit File

systemctl enable podman.socket
