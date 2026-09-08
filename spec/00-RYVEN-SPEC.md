# Ryven — Grill-Me Spec
# Round 1+ decisions. Updated as we go.

## Images
Two images only, both Turing+ NVIDIA open KMOD, no legacy driver support (no 580xx, no Pascal/Maxwell/Volta):
1. **ryven-nvidia-open** — ublue kinoite-main (KDE Plasma), SDDM inherited
2. **ryven-wl-nvidia-open** — ublue base-main, Hyprland + Quickshell + greetd/gtkgreet

## Kernel
- `kernel-cachyos-lto` (Clang + ThinLTO, x86-64-v3, 1000Hz, BORE, sched-ext, NTSync) from bieszczaders COPR
- Custom tuning stack from same COPR: scx-scheds, scx-manager, ananicy-cpp, cachyos-settings

## NVIDIA (open kernel modules, Turing+ only)
- Source: RPMFusion `akmod-nvidia` (595+ defaults to open KMOD for Turing+; nvidia-gpu-firmware from RPMFusion for signed GSP blobs)
- Built at image build time for CachyOS-LTO kernel via patched `akmods-ostree-post` (CC=clang LD=ld.lld LLVM=1 KCFLAGS=-fno-lto)
- Rebuild verification: `modinfo -F vermagic nvidia` must match in-tree module vermagic at build time, else fail build
- NO legacy 580xx support. No auto-detect. Pre-Turing GPU = unsupported. Documented.
- Services explicitly `systemctl enable` in Containerfile (image-name contract, no first-boot detection for driver enable): nvidia-persistenced, nvidia-suspend, nvidia-hibernate, nvidia-resume
- NO custom xorg.conf / X11 configuration (XWayland unsupported for custom tuning; relies on nvidia-open 610+ defaults; legacy X11 sessions not provided)
- Baked kargs add: nvidia.NVreg_PreserveVideoMemoryAllocations=1 (VRAM preserve across S3 sleep, eliminates post-resume black screen)

## Secure Boot / Boot
- UKI (Unified Kernel Image) with systemd-boot (not GRUB)
- Clean install only (no `bootc switch` from GRUB-based ublue images)
- One long-lived MOK key (DER in repo, private key as GitHub Actions secret), `ujust enroll-secure-boot-key`
- `sbsign` in CI with separate SIGNING_SECRET/UKI_SIGNING_KEY secret (cosign = ECDSA, sbsign = RSA; verify if can share key or use two)

## Kernel cmdline
Split into baked (signed, measured, stable PCR 12) vs first-boot detected. Baked UKI cmdline (frametime-stability tuned, pure NVIDIA desktop):
```
panic=10 nowatchdog nmi_watchdog=0 split_lock_detect=off usbcore.autosuspend=-1
zswap.enabled=1 zswap.compressor=lz4 zswap.zpool=zsmalloc zswap.max_pool_percent=40
nvidia_drm.modeset=1 nvidia_drm.fbdev=1 nvidia_drm.abnt_hdmi_deepcolor=1
nvidia.NVreg_EnableGpuFirmware=1 nvidia.NVreg_EnableResizableBar=1
nvidia.NVreg_PreserveVideoMemoryAllocations=1
systemd.log_level=notice mitigations=auto
kernel.core_pattern=|/bin/false rootflags=subvol=root rw
pcie_aspm=off iommu=pt
tsc=reliable clocksource=tsc
transparent_hugepage=always
random.trust_cpu=on audit=0
rcu_nocbs_poll=0 rcutree.enable_rcu_lazy=1
processor.max_cstate=1 intel_idle.max_cstate=1
nouveau.modeset=0 i915.modeset=0 amdgpu.si_support=0 amdgpu.cik_support=0 radeon.si_support=0 radeon.cik_support=0
sysfb.disable_modeset=1 simplefb.blacklist=1
modprobe.blacklist=pcspkr,snd_pcsp
```
- No `rhgb quiet` (verbose boot, no Plymouth splash, lower boot latency)
- `processor.max_cstate=1` locks cores to C1 for zero deep-C-state wakeup jitter (~15-20W higher idle power; escape via `ujust relax-cstates` for users who prefer lower idle power over absolute frametime consistency)
- `iommu=pt` cuts PCIe transaction latency without disabling IOMMU security
- `tsc=reliable` disables clocksource watchdog (eliminates 1ms+ periodic jitter spikes)
- `transparent_hugepage=always` reduces TLB misses for large game heap mappings
- Driver blacklists prevent nouveau/amdgpu/i915/radeon from loading (pure NVIDIA-only image, no Optimus/laptop iGPU support per scope)
- `sysfb.disable_modeset=1` eliminates the common simpledrm/simplefb handoff black screen delay on boot with nvidia-drm
- First-boot hardware-detect unit adds CPU-specific flags (e.g. `amd_pstate=active` on AMD) to `/etc/kernel/cmdline.d/` (outside signed UKI, PCR 12 stays stable; idempotent, no karg churn)
- `$ESP/loader/entries.conf` overrides work when Secure Boot is off
- `ujust nvidia-disable-rebar`, `ujust enable-mitigations` / `disable-mitigations`, `ujust relax-cstates` escape hatches exist for all baked kargs users may want to override
- DROPPED: nvidia.NVreg_EnablePCIeGen3=1 (caps Gen4/Gen5 cards for no reason)

## Scheduler
- `scx_lavd` default, enabled early via systemd service
- `ujust switch-scheduler <name>` for bpfland/cachy/rusty etc.
- `ananicy-cpp` with CachyOS + custom Steam/Proton/Heroic/Bottles/Lutris gaming rules

## Hyprland (ryven-wl-nvidia-open only)
- Source: Terra hyprland subrepo (hyprland + all hypr-* utilities)
- VRR mode: `vrr = 2` (fullscreen only)
- Tearing: `allow_tearing` for fullscreen windows matching gaming client regex ONLY (steam_app_*, wine, proton, hl2_linux, Lutris, heroic, bottles, gamescope, cs2, factorio, native Linux game classes). User-editable drop-in at `~/.config/hypr/conf.d/tearing.conf`. Desktop/terminals/browsers/video stay tearfree.
- Drop all legacy NVIDIA Wayland workaround env vars (NVD_BACKEND, GBM_BACKEND, WLR_NO_HARDWARE_CURSORS, __GLX_VENDOR_LIBRARY_NAME, CLUTTER_DEFAULT_VBLANK). Rely on explicit sync + nvidia-open 610+. `ujust nvidia-legacy-workarounds` for those who need old vars back.
- Hyprland window-event hook inhibits hypridle/DPMS/lock when a fullscreen gaming window (tearing regex) is focused.
- Display manager: greetd + gtkgreet (lean, no KDE/GNOME bloat), Ryven-themed CSS, hyprlock for in-session lock
- Seat/polkit preconfigured
- First boot: ublue-firstboot TUI (username/password/autologin) + cloud-init/ignition support for BIB/ISO installs

## Gaming infra (both images)
- MangoHUD: NOT shipped by default (users enable per-game via MANGOHUD=1 or layer)
- Gamescope: installed, nested only (launch via launch option or quickshell action), NO gamescope-session boot session
- Gamemode: NOT installed (replaced by scx_lavd + ananicy-cpp gaming rules + global performance governor defaults)
- ReBar forced via NVreg, `ujust nvidia-disable-rebar` opt-out

## QuickShell (ryven-wl-nvidia-open only)
"All in":
- Replaces: bar, app launcher, window switcher, notification center, OSDs (volume/brightness/performance/gamemode), no waybar/wofi/rofi/mako
- Controls provided: scheduler switching, power profiles, NVIDIA fan/overclock/features, display VRR/tearing/refresh, audio/brightness/bluetooth/network, distrobox management, rpm-ostree updates/rollbacks, game launch, AI panel
- Unprivileged (user) quickshell, privileged `ryven-control` systemd D-Bus service (root) with polkit allowlist for ~20 actions
- Single D-Bus/socket API is the control plane for: Quickshell UI, AI agents (via MCP), CLI wrapper, ujust recipes — one path of truth
- Agentic AI = MCP server exposes ryven-control actions over stdio/TCP

## AI runtime (ryven-wl-nvidia-open only)
Shipped preinstalled:
- **Pi** (@earendil-works/pi-coding-agent, npm -g) — terminal coding agent CLI, multi-provider
- **OpenCode** (opencode-ai, Go binary via official install script) — terminal TUI + desktop app (beta Linux), 75+ providers, LSP, MCP, sessions
- **llama.cpp** (via https://llama.app/install.sh with CUDA backend forced) — local inference engine, auto-detects NVIDIA, no model shipped; `llama-server` for OpenAI-compatible local endpoint; Pi/OpenCode preconfigured to discover it
- **t3code** from Terra — minimal web/desktop GUI over Codex/Claude-Code/OpenCode CLI agents
- CLI `ryven` wrapper for the control API (scripting)
- Quickshell AI panel sends prompts to whatever backend user configures (API or local llama-server)
- AI user in a dedicated group (not full wheel) with polkit-scoped permissions for ryven-control actions

## Terminal / Editor (ryven-wl-nvidia-open)
- Default terminal: Ghostty (Terra), `xdg-terminal-exec` set, ligatures, Kitty keyboard protocol, sixel
- Secondary terminal: Kitty (Fedora repos), themed to match
- GUI editor: Zed (Terra) only — fast, native Wayland, native Pi/LM integration, no VSCodium
- Neovim present by default (Fedora ships it), no starter config bloat

## Tuned / Power
- `tuned` + `tuned-ppd` (replaces power-profiles-daemon, which is masked)
- Custom profile `ryven-gaming` (always active, desktop-only, no battery profile exists):
  - Governor: `performance` (all cores max turbo 100% of the time; scx_lavd owns task placement)
  - EPP: `performance`, EPB=0 for Intel
  - kernel.sched_autogroup_enabled=0, sched_cfs_bandwidth_slice_us=3000, sched_migration_cost_ns=5000000, sched_min_granularity_ns=1500000, sched_wakeup_granularity_ns=1000000
  - kernel.split_lock_mitigate=0, nmi_watchdog=0
  - Memory: vm.overcommit_memory=1, overcommit_ratio=80, swappiness=1, dirty_ratio=20, dirty_background_ratio=5, dirty_expire_centisecs=600, dirty_writeback_centisecs=1500, page-cluster=0, min_free_kbytes=262144 (scaled at first boot for <32GB RAM)
  - IO: NVMe/SATA SSD scheduler = `kyber` (low-latency multi-queue), nr_requests=1024, read_ahead_kb=128; HDD (detected) = bfq with larger readahead
  - Power savings DISABLED on all buses: PCIe ASPM=performance, SATA LPM=max_performance, Wi-Fi power save=off, USB autosuspend=off, audio runtime PM=off
  - NVIDIA hooks: Coolbits=28 (overclock/fan control), GpuPowerMizerMode=1 (fixed max clock, no ramp)
- No battery profile, no AC/Battery switching (Ryven is desktop-only; laptop/Optimus/Prime is out of scope)
- UPower present solely to report wireless controller/headset/mouse battery levels

## Filesystem
- Btrfs mount options (systemd-fstab-generator drop-in): `compress=zstd:3,noatime,space_cache=v2,discard=async` (no autodefrag, SSD-hostile)
- Swap: zram-generator DISABLED. zswap enabled (lz4, zsmalloc, 40% pool) in front of real swap partition created by BIB/anaconda at install time.
- No disk swapfile, no snapper snapshots. bootc rollback handles /; /home has no auto-snapshot.

## Audio
- PipeWire + WirePlumber (stock Fedora) with tuned defaults:
  - Adaptive quantum 256/48kHz → 1024 for low latency without crackle
  - User added to `realtime` group at first boot; limits.d: memlock unlocked, rt_prio=99
  - wireplumber ordered after nvidia-drm enumeration (cold-boot HDMI audio fix for nvidia-open)
  - WirePlumber rnnoise AI mic noise suppression built in (no EasyEffects/PulseEffects shipped)
  - OpenAL Soft HRTF enabled (headphone positional audio for native games)

## Input / Peripherals
- libinput mouse accel default: `flat` (1:1 raw input)
- Hardware cursors, explicit sync, no software cursor override
- All hid_nintendo / hid-sony / hid-microsoft modules loaded at boot via modules-load.d
- `xone`, `xpadneo`, `openrazer` kmods built via akmods at image build (Clang-LTO)
- steam-devices udev rules (Steam RPM dep)
- `ujust force-poll-rate <hz>` opt-in for mice that support it (no forced 8000Hz default)

## Gaming Launchers / Compatibility
- **Steam:** RPMFusion nonfree RPM (pulls 32-bit multilib NVIDIA/Wine libs; no flatpak)
- **Faugus Launcher:** faugus/faugus-launcher COPR (RPM; GTK4, UMU-Launcher based, DW/CachyOS Proton support)
- **Heroic Games Launcher:** Terra RPM (Epic/GOG/Amazon)
- **ProtonPlus:** wehagy/protonplus COPR (RPM; GTK4 compatibility-tool manager; supports Steam + Faugus + Heroic)
- **umu-launcher:** Fedora/Terra (Faugus dep)
- Multilib: wine-core 32+64-bit, wine-mono, dxvk, vkd3d from RPMFusion + Terra
- Proton variants (GE, CachyOS, TKG, DW, etc.): user-managed via ProtonPlus; not pre-pinned
- NOT shipped: Lutris, Bottles, MangoHUD (opt-in per-game), gamemode (replaced by scx_lavd+ananicy+tuned).

## Build / CI/CD
- Two Containerfiles: `Containerfile.kde`, `Containerfile.wl`; shared shell helper library in `build_files/`
- Multi-stage build per image:
  1. **akmods-builder:** installs CachyOS-LTO kernel-devel/headers + repos + toolchain, runs patched akmods (CC=clang LD=ld.lld LLVM=1 KCFLAGS=-fno-lto) for nvidia, xone, xpadneo, openrazer; produces RPMs
  2. **base-os:** `rpm-ostree override remove` stock Fedora kernel, installs kernel-cachyos-lto + CachyOS addons (scx-scheds, scx-manager, ananicy-cpp, cachyos-settings), kmods from stage 1, RPMFusion nvidia userspace, Terra packages (mesa, mpv, hyprland*, vesktop, heroic, zed, ghostty, llama.cpp, pi/OpenCode/t3code), COPRs (faugus-launcher, protonplus, zen-browser), Brave official repo, all core apps/cli/gaming/tuning/theming packages; writes configs (systemd, tuned, hyprland, quickshell, env.d, modprobe.d, sysctl, polkit, fonts, cursors, themes)
  3. **uki-build:** kernel-install produces UKI (kernel+initrd+microcode+baked-cmdline+Ryven cmdline), sbsign with UKI_SIGNING_KEY, systemd-boot entries copied to /boot/EFI/Linux/
  4. **final:** ldconfig/dracut/ostree commit; runs verify.sh (see below); cosign sign OCI manifest; push to GHCR
- Triggers: weekly Sat 0300 UTC (full rebuild), push to main, tag `vYYYY.MM.DD` (immutable release), manual workflow_dispatch hotfixes, PR builds (build but don't push; PR comment with diff/size/package list)
- `verify.sh` (fail-build on any assertion):
  - nvidia kmod vermagic matches in-tree module vermagic (Clang/LTO build correctness)
  - `modprobe -n nvidia`, `modprobe ntsync` succeed (no missing symbols)
  - All nvidia.ko signed with MOK key (pesign check)
  - UKI PE32+ well-formed and sbsign-verified
  - nvidia systemd units all enabled (suspend/resume/hibernate/persistenced)
  - tuned active profile = ryven-gaming; scx_lavad enabled; key tuned sysctls verified (governor=performance, swappiness=1, default_qdisc=cake, tcp_congestion_control=bbr, etc.)
  - `rpm -q` succeeds for all expected packages
  - `opencode --version`, `pi --version`, `llama-cli --version`, `t3 --version` return version strings
  - `vainfo` reports NVDEC/nvidia driver
  - wl image: `hyprctl version` >= 0.48 with explicit_sync; no /etc/X11/xorg.conf exists
  - fc-match returns correct UI/mono fonts
  - UKI embedded cmdline contains all baked kargs and does NOT contain dropped kargs (no NVreg_EnablePCIeGen3)
  - Size budget enforced: wl ≤ 7 GB, KDE ≤ 9 GB uncompressed
- Signing: cosign (existing SIGNING_SECRET ECDSA) for OCI; sbsign with separate UKI_SIGNING_KEY (RSA) for UKI
- OSTree delta / size optimizations (priority):
  - Single ostree commit per build; zstd level 19 compression for smaller artifacts
  - rpm-ostree override operations run in one pass to minimize delta churn
  - Multi-stage build shares a common CachyOS+NVIDIA+tuned base layer between wl/KDE images
  - OSTree static deltas generated alongside image on GHCR
  - dnf clean all; strip /usr/share/gtk-doc/, /usr/share/doc/, non-en_US man pages; delete akmod build logs
- GHCR tags: `:latest`, `:44` (Fedora major), `:vYYYY.MM.DD` immutable
- Target: x86_64-v3 only; image metadata advertises requirement (bootc refuses non-v3 CPUs). No v2, no arm64.
- ISO builds DISABLED. OCI images only. Users rebase from a preinstalled bootc system; migration path from GRUB-based ublue documented via `ujust ryven-migrate` (reconfigure ESP for systemd-boot), but no official ISO artifact.
- Docs/website auto-generated from spec/ source of truth; no manual divergence
- Branch protection: green CI + cosign verification required before merge. Renovate only for our own source pins (BIB digest, quickshell SHA, pi/opencode versions), not distro packages. No Dependabot. No benchmarking in CI (no GPU in runners). No automatic PR screenshots.

- Default aesthetic: minimal dark high-contrast (Catppuccin Mocha base, neutral accent, no gamer-neon)
- Animations: tasteful minimal (workspace slide + 150ms window open fade; all animation speeds/disabling exposed in quickshell/KDE settings for zero-overhead competitive mode)
- Wallpapers: curated pack of ~10 dark wallpapers (abstract/landscape/minimal), one Ryven-branded geometric dark default; users add custom wallpapers from ~/Pictures/Wallpapers
- Preinstalled cursor themes (switchable via quickshell/KDE/ujust):
  - Bibata Modern Ice (dark default)
  - Adwaita (upstream)
  - capitaine-cursors (macOS-style)
  - Hackneyed X11 cursors (retro/bitmapped)
  - Simp1e (minimal outlined)
  - All configured for NVIDIA hardware cursor compatibility, no software cursor fallback required
- Preinstalled fonts (switchable): Inter (default UI), JetBrains Mono Nerd (default monospace/terminal), Noto CJK + Noto Color Emoji, Fira Code Nerd, Cascadia Code Nerd, Iosevka Term Nerd, Roboto, Cantarell
- Fontconfig tuning: antialias=true, hintslight, lcd-default, RGB subpixel
- Preinstalled icon themes: Papirus Dark (default), Papirus Light, Breeze, Tela Dark, Qogir Dark, Numix Circle
- Light mode variants shipped for all themes/cursors/icons; dark default
- wl image: qt6ct + kvantum + nwg-look + xdg-desktop-portal-gtk to keep GTK3/4/Qt apps in sync with selected theme; KDE image uses native kde-gtk-config/systemsettings
- Quickshell theming (wl image):
  - Live settings panel for theme, accent color, icon pack, cursor, UI/mono font, animation speed, wallpaper, bar layout/position
  - Declarative config in ~/.config/ryven/theme.toml; user drop-in themes in ~/.config/ryven/themes/
  - ryven-control D-Bus method Theme.Set applies theme system-wide (GTK/Qt/Hyprland/terminals/cursors/icons) in one call
  - `ujust theme <preset>` CLI equivalent for scripting/AI
- KDE image: same font/cursor/icon/wallpaper pack preinstalled for visual parity; uses native KDE systemsettings for switching.

## Terminals
- wl image: Ghostty default, Kitty secondary (xdg-terminal-exec set to Ghostty)
- KDE image: Konsole inherited from kinoite-main, Ghostty + Kitty added for parity, all three themed to match active theme

- File manager: pcmanfm-qt; archive: ark; gvfs-smb/mtp/afc for network/phone mounts; unzip/p7zip/unar/zstd/xz
- Shell: bash default; starship prompt enabled system-wide for all users
- CLI: eza, fd-find, ripgrep, bat, fzf, zoxide, htop, btop, nvtop, duf, ncdu, git, git-lfs, gh (GitHub CLI), just, jq, yq, curl, wget
- Dev/editors: Zed, Neovim, distrobox (podman pulled as dep; no docker default)
- System utilities: pavucontrol, blueman, network-manager-applet, polkit-gnome (Wayland auth agent), xdg-desktop-portal-hyprland + -gtk, grim+slurp+swappy+wf-recorder (screenshots/screen recording), cliphist (quickshell-integrated clipboard manager), nwg-displays (monitor layout GUI), wlogout (keybind power menu), system-config-printer, udisks2
- NOT installed: swaync/mako/dunst (quickshell handles notifications), EasyEffects/pulseeffects, gamemode/MangoHUD/Lutris/Bottles, fish/zsh, glab/direnv/lazygit/docker, gufw
- Browsers:
  - Firefox (Fedora RPM): policies.json with VA-API enabled (NVDEC), uBlock Origin preinstalled, privacy hardening
  - Zen Browser: sneexy/zen-browser COPR RPM (Firefox fork), inherits VA-API policy
  - Brave: official brave.com signed RPM repo, managed policy for VA-API / Wayland ozone
- Comms: vesktop (Terra RPM, Vencord Discord with Wayland/NVIDIA screenshare fix)
- Media: mpv (Terra build, NVDEC default)
## Config Management (ostree model)
- System defaults shipped read-only in /usr: tuned profiles, systemd units, udev/modprobe.d/sysctl.d/environment.d/limits.d/polkit actions, UKI cmdline.d fragments, hypr/quickshell/ryven-control defaults, ujust/distrobox recipes, fontconfig/theme defaults
- /etc is mutable with ostree 3-way merge; hardware-detect writes one /etc/ryven-hardware.toml, MOK/bootc state persists; no random config sprawl
- First-boot skel copied to new user (from ublue-firstboot): hyprland.conf with /usr includes + user conf.d drop-in, quickshell starter config, ryven/theme.toml, starship/bashrc with aliases (eza/bat/ll), ghostty/kitty themed configs, pcmanfm-qt defaults, Pi AGENTS.md with ryven-control/llama-server hints, OpenCode config.json with MCP entry for ryven-control
- systemd-sysusers/tmpfiles.d create ryven runtime user (ryven-control), games group (/dev/ntsync), runtime dirs

## Security / Polkit / Privileges
- wheel group: passwordless sudo (interactive convenience)
- Generic polkit: Fedora defaults retained (routine seat actions no-auth, destructive actions auth_admin_keep)
- ryven-control D-Bus three-tier policy:
  - `ryven.*.read` (sensors/state): no auth on local active seat
  - `ryven.*.toggle` (scheduler/VRR/theme/audio/brightness/fan): no auth on local active seat
  - `ryven.*.system` (rpm-ostree/kargs/firewalld/systemd/MOK): auth_admin_keep even with passwordless sudo
- SSH disabled by default; firewalld enabled workstation zone; kernel.sysrq=244; kernel lockdown automatic when Secure Boot enrolled; autologin opt-in via ublue-firstboot; MOK enroll user-initiated only; no mandatory firejail/bubblejail app wrapping
- Mitigations: `mitigations=auto` (kernel default; no force-off, no force-on, CPU-aware selection). `ujust enable-mitigations` / `disable-mitigations` for override

## Firmware / Microcode
- CPU microcode (intel-ucode, amd-ucode via microcode_ctl) included in UKI initrd (early load)
- fwupd service enabled; no background fwupd-refresh timer; `ujust firmware-update` runs on demand; LVFS updates for UEFI/peripherals
- NVIDIA GPU firmware: nvidia-gpu-firmware RPMFusion package (GSP/GTXGB), not fwupd

## Locale / Time
- Default locale en_US.UTF-8 (user-changeable)
- Timezone set by user at install/firstboot (not baked); systemd-timesyncd NTP default; RTC=UTC; keymap=us default

## llama.cpp / AI runtime install detail
- llama.cpp built from source at image build time via cmake `-DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release` against NVIDIA/CUDA from RPMFusion; x86-64-v3/AVX2/AVX512 optimizations; llama-cli, llama-server, llama-gguf-split, llama-perplexity in /usr/bin; systemd user unit for llama-server on port 8080 (opt-in `ujust ai-server-start`)
- Pi (@earendil-works/pi-coding-agent) via npm -g (global)
- OpenCode (opencode-ai) via official install script to /usr/local/bin, desktop file for opencode-desktop beta, preconfigured for 75+ providers and MCP
- t3code via Terra RPM (not COPR); provides GUI over Codex/Claude-Code/OpenCode
- Pi/OpenCode preconfigured to discover local llama-server at http://127.0.0.1:8080
- `ujust setup-ai` walks through API keys and optional default llama.cpp model pull

## AI runtime / ryven-control common to both images
- ryven-control D-Bus service API identical on both images (same method names, same polkit tiers)
- MCP server wraps ryven-control over stdio/TCP for AI agents (any MCP-compatible client — Claude Desktop, Cursor, Cline, aider, Pi, OpenCode)
- AI runs as primary user (no sandboxed distrobox); polkit tiers govern privileged actions regardless of how agent is invoked
- CLI `ryven` wrapper for scripting system actions
- Quickshell is wl-only; KDE ships a Ryven Plasmoid system tray applet consuming the same ryven-control API

## uJust Recipes (1.0)
- enroll-secure-boot-key, switch-scheduler, nvidia-enable/disable-rebar, nvidia-legacy-workarounds, force-poll-rate, theme, firmware-update, update (bootc), rollback, changepassword
- distrobox-create-arch/fedora/ubuntu, distrobox-delete
- install-mangohud, install-gamemode (opt-in)
- ryven-migrate (systemd-boot ESP migration path for switchers), enable/disable-mitigations
- setup-ai, configure-nvidia-overclock, version, verify (post-install drift check same checks as build verify.sh), clean (prune)

## Base Image Versioning
- ublue base images (kinoite-main, base-main) PINNED to specific SHAs in FROM directives; Renovate auto-opens weekly bump PRs that require CI green to merge (protects against bad upstream pushes). CachyOS COPR, RPMFusion, Terra, COPRs always pulled at latest (unpinned) in every build; weekly Saturday rebuilds use current metadata.
- No `latest` tag in FROM anywhere in Containerfiles; all external binaries (BIB, Pi, OpenCode, quickshell) pinned to verified SHAs/versions, Renovate-managed.

## Update UX
- Background CHECK only once per day (no auto-download, no auto-update, no auto-staging, no auto-reboot). Plasmoid/quickshell indicator shows update availability; user explicitly triggers download+apply via `ujust update` (host) or Bazaar (flatpaks). Gaming sessions never interrupted.
- Staged updates apply on reboot (bootc standard); no forced reboot after staging; indicator shows "reboot required".

## NVIDIA Persistence
- nvidia-persistenced enabled, PersistenceMode=1 always; GpuPowerMizerMode=1 max clock. Zero GPU app startup latency, consistent with "no power savings" stance.

## Flatpak Integration
- Fedora Flatpak repo removed; Flathub enabled system-wide. Only two preinstalled flatpaks: Bazaar (io.github.kolunmi.Bazaar, app store), Flatseal (com.github.tchx84.Flatseal, permission manager).
- Global flatpak overrides (/etc/flatpak/overrides/global) ensure ALL flatpaks (preinstalled AND user-installed) automatically inherit host theming:
  - Ro access to /usr/share/themes, /usr/share/icons, /usr/share/fonts, ~/.themes, ~/.icons, ~/.fonts, xdg-config/gtk-3.0, xdg-config/gtk-4.0
  - Wayland socket, dri device, fallback-x11 socket, ipc sharing enabled by default
- xdg-desktop-portal-gtk propagates cursor, GTK/Qt theme, font, and scaling settings to all flatpaks automatically on install
- NVIDIA flatpak GL/GL32 extensions installed at image build matching host driver version (no llvmpipe fallback for flatpak apps)
- `ujust fix-flatpak-theme` repair command for edge cases
- Flatseal available for per-app permission customization
- No global sandbox escape; per-app permissions granted explicitly.

## Hyprland Session (wl image)
- Wayland-only session; no X11 session shipped; greetd registers Hyprland only; XWayland installed for Steam/Proton/legacy games
- Hyprland starts via systemd user target (hyprland-session.target) so quickshell/hyprlock/hypridle/cliphist/ryven-control user services are properly ordered
- Environment variables exported globally via systemd-environment-generator (visible to ALL processes including dbus-activated services, launchers, agents):
  - XDG_CURRENT_DESKTOP=Hyprland, XDG_SESSION_TYPE=wayland
  - LIBVA_DRIVER_NAME=nvidia, PROTON_ENABLE_NTSYNC=1
  - QT_QPA_PLATFORM=wayland, QT_WAYLAND_FORCE_DPI=-1
  - MOZ_ENABLE_WAYLAND=1, MOZ_DISABLE_RDD_SANDBOX=1 (Firefox VA-API on NVIDIA)
  - No legacy NVIDIA workaround vars (NVD_BACKEND/GBM_BACKEND/WLR_NO_HARDWARE_CURSORS per Q13)
- hyprpm installed (ships with hyprland); no third-party plugins preinstalled

## System Daemons / Logging
- systemd-homed: DISABLED (standard /var/home Btrfs directories; bootc default)
- OOM handling: **nohang** replaces systemd-oomd (desktop-tuned, prioritizes keeping compositor/Steam/AI agents alive, kills runaway processes first); systemd-oomd masked; nohang desktop config preset
- journald hardening for reduced disk/memory pressure:
  - Storage=persistent, SystemMaxUse=100M, SystemMaxFileSize=10M, MaxRetentionSec=3day, Compress=yes
  - RateLimitBurst=20 / 30s (throttle spammy services)
  - ForwardToSyslog=no
  - Systemd log level: notice (kernel cmdline `systemd.log_level=notice`); mask debug-shell.service
  - kernel printk restricted to warn+ for non-critical messages
- Coredumps ENTIRELY DISABLED: `kernel.core_pattern=|/bin/false` via sysctl; systemd-coredumpd.socket/service masked; no debug symbols in base image; zero coredump disk writes
- No crash dumps, no kexec/kdump (server infrastructure, irrelevant for gaming)

## MOTD / Welcome

- Minimal MOTD on first terminal login: Ryven version, kernel, NVIDIA driver, active scheduler/tuned profile, pointer to ujust setup-ai and ujust --help. No mandatory GUI welcome wizard.

- Base: kinoite-main, inherits Dolphin/Konsole/Spectacle/KDE settings by default; layers the same CLI/browser/utility/theming/gaming set as the wl image
- DM: Plasma Login Manager (plasmalogin, default in Fedora 44 kinoite Plasma 6.6+), Wayland mode, configured via /etc/plasmalogin.conf.d/ drop-in for Ryven dark theme + default wallpaper; SDDM removed entirely
- Baloo: DISABLED/blocked (file indexer masked; game library churn avoided entirely)
- Akonadi + KDE PIM: stripped (akonadi-server, kdepim-runtime, kmail, korganizer, kaddressbook removed)
- KWin defaults: VRR automatic fullscreen, tearing allowed for fullscreen windows matching the same gaming regex as Hyprland (applied via KWin window rules), animations default 150ms (user can dial to zero via plasmoid), explicit sync enabled default (Plasma 6.2+)
- Discover + PackageKit: masked and removed. Bazaar (Flathub flatpak: io.github.kolunmi.Bazaar) installed system-wide as Flatpak app store (handles Flatpak apps only). Host/RPM layer updates handled via ryven-control / ujust / a small Ryven Updater plasmoid
- KRunner: kept; Baloo file-content search plugins removed (Baloo is off); calculator, apps, commands, web shortcuts, and Bazaar search provider active
- Flatpak: Fedora Flatpak repo removed; Flathub enabled system-wide. ONLY two preinstalled flatpaks: Bazaar, Flatseal (com.github.tchx84.Flatseal, permission manager). All other flatpaks installed by user via Bazaar.
- ryven-control D-Bus API is identical on both images (same methods, same polkit tiers). KDE ships a Ryven Plasmoid system tray applet for scheduler/VRR/tearing/updates/gaming toggles (same branding as quickshell on wl). Quickshell is wl-only, not installed on KDE.
- Terminal parity: Konsole inherited, Ghostty + Kitty added and themed to match


## Network
- Stock Fedora defaults retained for firewalld, wpa_supplicant, NetworkManager, systemd-resolved, NetworkManager-wait-online, IPv6 privacy extensions (no iwd swap, no BBR/network buffer/UPnP changes that risk compatibility)
- Safe zero-regression sysctls in ryven-gaming tuned profile:
  - `net.ipv4.tcp_fastopen=3` (TFO client+server for faster connect to CDNs/Steam/voice)
  - `net.ipv4.tcp_thin_linear_timeouts=1` (faster loss recovery for thin game streams)
  - `net.core.netdev_budget=600`, `net.core.netdev_budget_usecs=16000` (process more packets per NAPI poll, reduce softirq latency spikes under simultaneous download+gaming)
  - `net.core.default_qdisc=cake`, `net.ipv4.tcp_congestion_control=bbr`, `sch_cake` and `tcp_bbr` modules loaded early (flow isolation + BBR for bufferbloat resistance; cake runs unshaped, no SQM config needed)
- No sqm-scripts, no ingress bandwidth shaping (fiber/5G/ethernet desktop audience).

## Containers / AI Sandbox
- No prebuilt distroboxes/toolboxes (image stays lean); `ujust` recipes create them on demand (Arch/Fedora/Ubuntu distroboxes with host GPU/audio/Wayland passthrough as needed).
- AI agents run as the primary user (no sandboxed distrobox for agents; no false sense of security). ryven-control polkit policy governs what privileged actions AI/UI can invoke, regardless of how the agent is launched.

## Codecs / Media / HDR
- Repo priority: Terra > RPMFusion for codec/ffmpeg/mesa/vaapi packages; RPMFusion fills gaps
- Full codec bundle preinstalled:
  - ffmpeg (Terra, all codecs enabled), all gstreamer1 plugins (base/good/bad/ugly/libav, prefer Terra), libavcodec-freeworld (fallback RPMFusion)
  - nvidia-vaapi-driver (Terra, bridges VA-API → NVDEC on nvidia-open)
  - mesa-vaapi-drivers (Terra), nv-codec-headers, vdpauinfo, libva-utils
  - mpv (Terra build) with NVDEC hardware decode default
  - OpenH264 repo enabled (Cisco binaries for WebRTC / Discord / browser screenshare)
- Global env: `LIBVA_DRIVER_NAME=nvidia` in environment.d (not a workaround; canonical VA-API driver selection for pure NVIDIA desktop, avoids nouveau misprobe)
- Firefox policies.json: enable VA-API for h264/h265/av1/vp9, force hardware decode (no about:config fiddling)
- Hyprland HDR: color management enabled (`explicit_sync=2`, color_manager=hyprland), BT.2020/HDR metadata passthrough for gamescope
- KDE Plasma 6.2+ HDR (inherited from kinoite-main) works OOTB
- NO gnome-codec-installer / codec-missing prompts

## NTSync
- CachyOS kernel has ntsync built in
- `ntsync` module loaded at boot via modules-load.d
- udev uaccess rule grants `/dev/ntsync` rw to users in `games` group (primary user added at first boot)
- `/etc/environment.d/99-ryven-gaming.conf` sets `PROTON_ENABLE_NTSYNC=1` (Proton/Wine auto-enable)
- FSYNC/ESYNC use stock defaults (already enabled by Wine/Proton)
