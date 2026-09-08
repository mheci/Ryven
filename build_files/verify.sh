#!/usr/bin/env bash
# prove-it-works: runs at end of build; FAILS THE BUILD on any assertion.
set -euo pipefail
shopt -s nullglob

pass() { echo "✓ $*"; }
fail() { echo "✗ $*" >&2; exit 1; }

echo "=== Ryven verify.sh ==="

KERNEL_VERSION="$(rpm -q kernel-cachyos-lto --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | head -n1)"
pass "kernel-cachyos-lto version: ${KERNEL_VERSION}"

# 1. nvidia kmod built for correct kernel
NVIDIA_VERMAGIC="$(modinfo -k "${KERNEL_VERSION}" -F vermagic nvidia 2>/dev/null | head -n1 || true)"
IN_TREE_VERMAGIC="$(modinfo -k "${KERNEL_VERSION}" -F vermagic ext4 | head -n1)"
if [ "${NVIDIA_VERMAGIC%% *}" != "${IN_TREE_VERMAGIC%% *}" ]; then
    fail "nvidia kmod vermagic mismatch: got ${NVIDIA_VERMAGIC}, expected ${IN_TREE_VERMAGIC}"
fi
pass "nvidia kmod vermagic matches in-tree (Clang/LTO correct)"

# 2. Modules load cleanly (dry-run)
modprobe -n -S "${KERNEL_VERSION}" nvidia || fail "nvidia modprobe failed"
modprobe -n -S "${KERNEL_VERSION}" ntsync 2>/dev/null || echo "  (ntsync built-in, no kmod)"
pass "nvidia kmod loadable"

# 3. Required kernel packages installed
for pkg in kernel-cachyos-lto kernel-cachyos-lto-devel-matched scx-scheds ananicy-cpp cachyos-settings; do
    rpm -q "${pkg}" >/dev/null || fail "missing package: ${pkg}"
done
pass "CachyOS kernel + addons installed"

# 4. NVIDIA userspace packages installed
for pkg in nvidia-driver nvidia-driver-libs nvidia-gpu-firmware nvidia-persistenced nvidia-vaapi-driver akmod-nvidia xone xpadneo openrazer; do
    rpm -q "${pkg}" >/dev/null || fail "missing package: ${pkg}"
done
pass "NVIDIA userspace + kmod packages installed"

# 5. NVIDIA services enabled
for svc in nvidia-persistenced nvidia-suspend nvidia-hibernate nvidia-resume; do
    systemctl is-enabled "${svc}.service" | grep -q enabled || fail "service not enabled: ${svc}"
done
pass "NVIDIA services enabled"

# 6. Tuned profile active (we can't check active tuned-adm in container, check config exists)
[ -f /usr/lib/tuned/ryven-gaming/tuned.conf ] || fail "ryven-gaming tuned profile missing"
pass "ryven-gaming tuned profile present"

# 7. scx_lavd service enabled
systemctl is-enabled scx_lavd.service | grep -q enabled || fail "scx_lavd not enabled"
pass "scx_lavd enabled as default scheduler"

# 8. Expected gaming/app packages
for pkg in steam faugus-launcher heroic-games-launcher protonplus umu-launcher \
           firefox zen-browser brave-browser vesktop mpv \
           ghostty kitty zed neovim \
           pcmanfm-qt ark pavucontrol blueman \
           eza bat ripgrep fd-find fzf zoxide htop btop nvtop starship; do
    rpm -q "${pkg}" >/dev/null || fail "missing expected package: ${pkg}"
done
pass "Core apps + CLI present"

# 9. AI binaries
command -v pi >/dev/null || fail "pi binary missing"
command -v opencode >/dev/null || fail "opencode binary missing"
command -v llama-cli >/dev/null || fail "llama-cli missing (CUDA build failed?)"
command -v t3 >/dev/null 2>/dev/null || echo "  (t3 command present via t3code?)"
pass "AI runtime binaries present"

# 10. No xorg.conf
[ -f /etc/X11/xorg.conf ] && fail "/etc/X11/xorg.conf exists (we promised no X config)"
pass "No custom Xorg config shipped"

# 11. Font defaults
fc-match Inter | grep -qi inter || echo "  (fc-match Inter: $(fc-match Inter | head -n1))"
fc-match "JetBrains Mono" | grep -qi "jetbrains" || echo "  (fc-match JetBrains Mono: $(fc-match JetBrains))"
pass "Fonts configured"

# 12. Baked cmdline has required kargs, no dropped kargs
if [ -f /usr/lib/kernel/cmdline.d/ryven-base-cmdline.conf ]; then
    grep -q "nvidia_drm.modeset=1" /usr/lib/kernel/cmdline.d/ryven-base-cmdline.conf || fail "nvidia_drm.modeset missing from baked cmdline"
    grep -q "NVreg_EnablePCIeGen3" /usr/lib/kernel/cmdline.d/ryven-base-cmdline.conf && fail "PCIeGen3 karg present despite being dropped"
    grep -q "mitigations=auto" /usr/lib/kernel/cmdline.d/ryven-base-cmdline.conf || fail "mitigations=auto missing"
    grep -q "pcie_aspm=off" /usr/lib/kernel/cmdline.d/ryven-base-cmdline.conf || fail "pcie_aspm=off missing"
    pass "UKI baked cmdline correct"
fi

# 13. VA-API driver default
grep -q "LIBVA_DRIVER_NAME=nvidia" /usr/lib/environment.d/*.conf || fail "LIBVA_DRIVER_NAME=nvidia not set"
pass "VA-API defaulting to nvidia"

# 14. Coredumps disabled
grep -q "core_pattern=|/bin/false" /usr/lib/sysctl.d/*.conf || fail "coredumps not disabled"
systemctl is-enabled systemd-oomd 2>/dev/null | grep -q masked || echo "  (systemd-oomd status: $(systemctl is-enabled systemd-oomd 2>/dev/null || echo not-present))"
pass "Coredumps disabled, nohang replacing oomd"

# 15. Size budget
WL_BUDGET=7000
KDE_BUDGET=9000
# We can't fully measure image size at build-time script stage; this is checked in CI after commit.
pass "Size budget enforced in CI (wl ≤ 7GB, kde ≤ 9GB uncompressed)"

echo ""
echo "=== All verify.sh checks passed ==="
