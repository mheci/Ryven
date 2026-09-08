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

echo "Installing core CLI utilities..."
dnf5 install -y --skip-unavailable --setopt install_weak_deps=False \
    bash-completion starship eza fd-find ripgrep bat fzf zoxide htop btop nvtop duf ncdu \
    git git-lfs gh just jq yq curl wget direnv lazygit \
    ujust ublue-os-just \
    grim slurp swappy wf-recorder cliphist nwg-displays wlogout \
    pavucontrol blueman network-manager-applet polkit-gnome system-config-printer udisks2 \
    gvfs gvfs-smb gvfs-mtp gvfs-afc p7zip unar unzip xz zstd ark

echo "Installing editors / terminals..."
dnf5 install -y --skip-unavailable --setopt install_weak_deps=False \
    neovim ghostty kitty zed

echo "Installing file manager / utilities..."
dnf5 install -y --skip-unavailable pcmanfm-qt tumbler thunar-archive-plugin

echo "Installing browsers..."
dnf5 install -y --skip-unavailable --setopt install_weak_deps=False \
    firefox zen-browser brave-browser

echo "Installing gaming launchers + multilib Wine..."
dnf5 install -y --skip-unavailable --setopt install_weak_deps=False \
    steam faugus-launcher heroic-games-launcher protonplus umu-launcher vesktop \
    wine-core wine-core.i686 wine-mono dxvk dxvk.i686 vkd3d vkd3d.i686 \
    gamescope mpv

echo "Installing fonts/cursors/icons/themes..."
dnf5 install -y --skip-unavailable --setopt install_weak_deps=False \
    inter-fonts jetbrains-mono-fonts fira-code-fonts cascadia-fonts iosevka-term-fonts \
    google-roboto-fonts cantarell-fonts google-noto-sans-cjk-fonts google-noto-emoji-fonts \
    bibata-cursor-themes capitaine-cursors adwaita-cursor-theme \
    papirus-icon-theme papirus-icon-theme-dark breeze-icon-theme tela-icon-theme qogir-icon-theme numix-icon-theme \
    catppuccin-gtk-theme catppuccin-kvantum-theme nwg-look qt6ct kvantum \
    fontconfig fontawesome-fonts

echo "Installing Hyprland + quickshell + wl-only packages..."
if [ "${IMAGE_VARIANT:-}" = "wl" ]; then
    dnf5 install -y --skip-unavailable --setopt install_weak_deps=False \
        hyprland hyprlock hypridle hyprpaper hyprcursor hyprpicker hyprsunset \
        xdg-desktop-portal-hyprland xdg-desktop-portal-gtk greetd gtkgreet \
        quickshell quickshell-quick
fi

echo "Installing KDE-specific overrides..."
if [ "${IMAGE_VARIANT:-}" = "kde" ]; then
    dnf5 install -y --skip-unavailable --setopt install_weak_deps=False \
        plasma-login-manager kde-gtk-config \
        --exclude=plasma-discover --exclude=PackageKit --exclude=packagekit-qt6 --exclude=akonadi* --exclude=kdepim* --exclude=kmail --exclude=korganizer --exclude=baloo*
    systemctl mask --no-reload sddm.service sddm-autologin.service 2>/dev/null || true
    systemctl enable --no-reload plasmalogin.service
    systemctl mask --no-reload baloo_file.service baloo_file_extractor.service akonadi.service 2>/dev/null || true
fi

echo "Core apps installed."
