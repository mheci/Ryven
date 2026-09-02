#!/bin/bash
# Build-time image invariants. No GPU; systemd is not PID 1.

set -ouex pipefail

fail=0
check() {
  local name=$1
  shift
  if "$@"; then
    echo "OK  ${name}"
  else
    echo "FAIL ${name}" >&2
    fail=1
  fi
}

check "firefox rpm" rpm -q firefox
check "git on PATH" command -v git
check "gh on PATH" command -v gh
check "mise on PATH" command -v mise
check "nvidia kargs" test -f /usr/lib/bootc/kargs.d/00-nvidia.toml
check "nvidia modprobe" test -f /usr/lib/modprobe.d/nvidia-gaming.conf
check "shader cache env" test -f /usr/lib/environment.d/50-ryven-shader-cache.conf
check "zswap kargs" test -f /usr/lib/bootc/kargs.d/10-zswap.toml
check "amd zen kargs" test -f /usr/lib/bootc/kargs.d/20-amd-zen.toml
check "ujust wrapper" test -x /usr/bin/ujust
check "ryven justfile" test -f /usr/share/ryven/justfile
check "chronyd enabled" bash -c '[[ $(systemctl is-enabled chronyd.service) == enabled ]]'
check "sshd not enabled" bash -c 's=$(systemctl is-enabled sshd.service 2>/dev/null || true); [[ $s != enabled ]]'
check "firewalld enabled" bash -c '[[ $(systemctl is-enabled firewalld.service) == enabled ]]'
check "nvidia kmod present" bash -c 'find /usr/lib/modules -name "nvidia*.ko*" -print -quit | grep -q .'
check "ffmpeg rpm" rpm -q ffmpeg
check "libva-nvidia-driver" rpm -q libva-nvidia-driver
check "zram generator disabled" bash -c '! systemctl is-enabled systemd-zram-setup@zram0.service 2>/dev/null | grep -qx enabled'
check "no firefox flatpak" bash -c '! command -v flatpak >/dev/null || ! flatpak info --system org.mozilla.firefox >/dev/null 2>&1'
check "ryven look-and-feel" test -f /usr/share/plasma/look-and-feel/org.ryven.desktop/metadata.json
check "ryven color scheme" test -f /usr/share/color-schemes/Ryven.colors
check "ryven wallpaper" test -f /usr/share/wallpapers/Ryven/contents/images/3840x2160.png
check "ryven kdeglobals" grep -q 'LookAndFeelPackage=org.ryven.desktop' /etc/xdg/kdeglobals
check "inter font default" grep -q 'font=Inter,' /etc/xdg/kdeglobals
check "darkly widgetStyle" grep -q 'widgetStyle=Darkly' /etc/xdg/kdeglobals
check "plasmalogin enabled" bash -c '[[ $(systemctl is-enabled plasmalogin.service) == enabled ]]'
check "sddm not enabled" bash -c 's=$(systemctl is-enabled sddm.service 2>/dev/null || true); [[ $s != enabled ]]'
check "io scheduler udev" test -f /usr/lib/udev/rules.d/60-ryven-io-scheduler.rules
check "ntsync udev" test -f /usr/lib/udev/rules.d/40-ryven-ntsync.rules
check "ntsync modules-load" test -f /usr/lib/modules-load.d/ntsync.conf
check "desktop sysctl" test -f /usr/lib/sysctl.d/70-ryven-desktop.conf
check "scx default lavd" grep -q 'SCX_SCHEDULER=scx_lavd' /etc/default/scx
check "scx_loader.toml" grep -q 'default_sched = "scx_lavd"' /etc/scx_loader.toml
check "scx_loader enabled" bash -c '[[ $(systemctl is-enabled scx_loader.service) == enabled ]]'
check "ananicy-cpp enabled" bash -c '[[ $(systemctl is-enabled ananicy-cpp.service) == enabled ]]'
check "bpftune enabled" bash -c '[[ $(systemctl is-enabled bpftune.service) == enabled ]]'
check "no cardwire" bash -c '! rpm -q cardwire >/dev/null 2>&1'
check "proton wayland" grep -q 'PROTON_ENABLE_WAYLAND=1' /usr/lib/environment.d/60-ryven-proton.conf
check "no WINEFSYNC" bash -c '! grep -q WINEFSYNC /usr/lib/environment.d/60-ryven-proton.conf'
check "flatpak first-boot unit" test -f /usr/lib/systemd/system/ryven-flatpak-setup.service
check "bees generator" test -x /usr/lib/systemd/system-generators/ryven-bees-generator
check "greenboot redboot-auto-reboot" bash -c '[[ $(systemctl is-enabled redboot-auto-reboot.service) == enabled ]]'
check "proton-cachyos vdf" bash -c 'find /usr/share/steam/compatibilitytools.d -name compatibilitytool.vdf | grep -q .'
# terra-gamescope: f44 spec exists, no NEVRA in terra44/multimedia/mesa (2026-09-02).
check "helium-browser-bin" rpm -q helium-browser-bin
check "gpu-screen-recorder" rpm -q gpu-screen-recorder
check "polychromatic" rpm -q polychromatic
check "docker group empty or absent" bash -c '
  if getent group docker >/dev/null; then
    members=$(getent group docker | cut -d: -f4)
    [[ -z ${members} ]]
  else
    true
  fi
'

if [[ ${fail} -ne 0 ]]; then
  echo "Image invariant checks failed." >&2
  exit 1
fi

echo "Image invariant checks passed."
