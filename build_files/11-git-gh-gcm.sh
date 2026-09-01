#!/bin/bash
# git, GitHub CLI, Git Credential Manager (Fedora + isolated COPR).

set -ouex pipefail
# shellcheck source=copr-helpers.sh
source /ctx/copr-helpers.sh

dnf5 -y install git gh git-credential-libsecret

copr_install_isolated "vdanielmo/git-credential-manager" git-credential-manager
