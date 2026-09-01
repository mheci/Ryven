#!/bin/bash
# Mozilla Firefox as Fedora RPM; drop the system Firefox Flatpak if present.

set -ouex pipefail

dnf5 -y install firefox

if command -v flatpak >/dev/null 2>&1; then
  flatpak uninstall --system -y org.mozilla.firefox || true
fi
