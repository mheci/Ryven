#!/usr/bin/env bash
# Basic retry helper for transient network failures
try() { for i in 1 2 3; do "$@" && return 0; echo "  retry $i/3 ($*)"; sleep 5; done; return 1; }
# Install full codec bundle (Terra first, RPMFusion fallback), VA-API defaults, Firefox policies.
set -euo pipefail

# OpenH264 repo (WebRTC)
dnf5 config-manager addrepo --from-repofile=https://codecs.fedoraproject.org/openh264/$(rpm -E %fedora)/x86_64/ || true

echo "Installing full codec stack (Terra first)..."
dnf5 install -y --skip-unavailable --setopt=install_weak_deps=False \
    ffmpeg ffmpeg-libs \
    gstreamer1-plugins-base gstreamer1-plugins-good gstreamer1-plugins-bad-free gstreamer1-plugins-bad-freeworld \
    gstreamer1-plugins-ugly-free gstreamer1-libav gstreamer1-plugin-openh264 \
    libavcodec-freeworld libva libva-utils vdpauinfo \
    nv-codec-headers libvdpau-va-gl \
    mpv \
    openh264 mozilla-openh264

# Firefox VA-API policy (enforce hardware decode, uBlock Origin, Wayland)
mkdir -p /usr/lib/firefox/distribution
cat > /usr/lib/firefox/distribution/policies.json <<'EOF'
{
  "policies": {
    "HardwareAcceleration": true,
    "MediaHardwareVideoDecoding": {
      "Enabled": true,
      "ForceVP9": true,
      "ForceAV1": true,
      "ForceH264": true
    },
    "Extensions": {
      "Install": ["https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi"],
      "Locked": ["uBlock0@raymondhill.net"]
    },
    "FirefoxHome": {
      "Search": true, "TopSites": true, "SponsoredTopSites": false, "Pocket": false, "Snippets": false
    },
    "DisableTelemetry": true,
    "UserMessaging": { "WhatsNew": false, "ExtensionRecommendations": false, "FeatureRecommendations": false, "UrlbarInterventions": false, "SkipOnboarding": true }
  }
}
EOF

echo "Codecs installed, VA-API defaulting to nvidia."
