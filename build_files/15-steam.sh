#!/bin/bash
# Steam native RPM from RPM Fusion nonfree (Fedora 44).

set -ouex pipefail

dnf5 -y install --enablerepo=rpmfusion-nonfree steam
