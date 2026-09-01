#!/bin/bash
# Preinstall Secure Boot / TPM tooling. Configuration is runtime-only via ujust.

set -ouex pipefail

dnf5 -y install \
  just \
  mokutil \
  shim \
  efibootmgr \
  cryptsetup \
  clevis \
  clevis-luks \
  clevis-dracut \
  tpm2-tools
