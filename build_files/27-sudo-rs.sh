#!/bin/bash
# sudo-rs alongside classic sudo (Fedora ships sudo-rs, visudo-rs, su-rs).

set -ouex pipefail

dnf5 -y install sudo-rs
