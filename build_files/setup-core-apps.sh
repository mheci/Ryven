#!/usr/bin/env bash
# Basic retry helper for transient network failures
try() { for i in 1 2 3; do "$@" && return 0; echo "  retry $i/3 ($*)"; sleep 5; done; return 1; }
# Install core CLI utilities, browsers, launchers, editors, terminal emulators.
set -euo pipefail
shopt -s nullglob

echo "Enabling COPRs for third-party packages..."
(dnf5 copr enable -y faugus/faugus-launcher 2>/dev/null && echo "faugus/faugus-launcher COPR enabled") || echo "WARNING: faugus/faugus-launcher COPR unavailable"
(dnf5 copr enable -y wehagy/protonplus 2>/dev/null && echo "wehagy/protonplus COPR enabled") || echo "WARNING: wehagy/protonplus COPR unavailable"
(dnf5 copr enable -y sneexy/zen-browser 2>/dev/null && echo "sneexy/zen-browser COPR enabled") || echo "WARNING: sneexy/zen-browser COPR unavailable"
(dnf5 copr enable -y errornointernet/quickshell 2>/dev/null && echo "errornointernet/quickshell COPR enabled") || echo "WARNING: errornointernet/quickshell COPR unavailable"

# Brave repo
dnf5 config-manager addrepo --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo || true
rpm --import https://brave-browser-rpm-release.s3.brave.com/brave-core.asc

# Helper: best-effort package install (failing packages don't break the build).
inst() {
    # Pre-create /opt so third-party packages (Zen, Brave, etc.) that unpack into /opt don't fail on missing dir
    mkdir -p /opt
    dnf5 install -y --skip-unavailable --setopt=strict=0 --setopt install_weak_deps=False "$@" 2>&1 || true
}

echo "Installing core CLI utilities..."
inst bash-completion starship eza fd-find ripgrep bat fzf zoxide htop btop nvtop duf ncdu \
    git git-lfs gh just jq yq curl wget direnv lazygit \
    ujust ublue-os-just \
    grim slurp swappy wf-recorder cliphist nwg-displays wlogout \
    pavucontrol blueman network-manager-applet polkit-gnome system-config-printer udisks2 \
    gvfs gvfs-smb gvfs-mtp gvfs-afc p7zip unar unzip xz zstd ark

echo "Installing editors / terminals..."
inst neovim ghostty kitty zed

echo "Installing file manager / utilities..."
inst pcmanfm-qt tumbler thunar-archive-plugin

echo "Installing browsers..."
# firefox is from Fedora base.
# NOTE: zen-browser (sneexy COPR) and brave-browser (official RPM) both install under /opt
# which in rpm-ostree OCI builds uses a special composefs/0755 layout that causes
# "cpio: mkdir failed - File exists" when running inside a container build. Install them
# via Flatpak (preinstalled user-facing) or via ujust post-rebase. For the base image
# we only ship Firefox; Brave/Zen users can flatpak install or add the repo post-boot.
inst firefox
# Still enable the COPRs/repos so users get them via `dnf install` post-rebase (no harm done)
(dnf5 copr enable -y sneexy/zen-browser 2>/dev/null) || true
# brave repo is already enabled earlier
echo "(Brave/Zen repos enabled; browsers installable post-rebase via flatpak or dnf)"

echo "Installing gaming launchers + multilib Wine..."
inst steam faugus-launcher heroic-games-launcher protonplus umu-launcher vesktop \
    wine-core wine-core.i686 wine-mono dxvk dxvk.i686 vkd3d vkd3d.i686 \
    gamescope mpv

echo "Installing fonts/cursors/icons/themes..."
inst inter-fonts jetbrains-mono-fonts fira-code-fonts cascadia-fonts iosevka-term-fonts \
    google-roboto-fonts cantarell-fonts google-noto-sans-cjk-fonts google-noto-emoji-fonts \
    bibata-cursor-themes capitaine-cursors adwaita-cursor-theme \
    papirus-icon-theme papirus-icon-theme-dark breeze-icon-theme tela-icon-theme qogir-icon-theme numix-icon-theme \
    catppuccin-gtk-theme catppuccin-kvantum-theme nwg-look qt6ct kvantum \
    fontconfig fontawesome-fonts

echo "Installing Hyprland + quickshell + wl-only packages..."
if [ "${IMAGE_VARIANT:-}" = "wl" ]; then
    inst hyprland hyprlock hypridle hyprpaper hyprcursor hyprpicker hyprsunset \
        xdg-desktop-portal-hyprland xdg-desktop-portal-gtk greetd gtkgreet \
        quickshell quickshell-quick
fi

echo "Installing KDE-specific overrides..."
if [ "${IMAGE_VARIANT:-}" = "kde" ]; then
    inst --exclude=plasma-discover --exclude=PackageKit --exclude=packagekit-qt6 --exclude=akonadi* --exclude=kdepim* --exclude=kmail --exclude=korganizer --exclude=baloo* \
        plasma-login-manager kde-gtk-config
    systemctl mask --no-reload sddm.service sddm-autologin.service 2>/dev/null || true
    systemctl enable --no-reload plasmalogin.service 2>/dev/null || true
    systemctl mask --no-reload baloo_file.service baloo_file_extractor.service akonadi.service 2>/dev/null || true
fi

echo "Core apps installed."
