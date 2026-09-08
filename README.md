# Ryven

Two gaming-first bootc/OCI images built on ublue:

- **ryven-nvidia-open** — KDE Plasma (kinoite-main), CachyOS-LTO kernel, NVIDIA open kernel modules, tuned for high-performance desktop gaming.
- **ryven-wl-nvidia-open** — Hyprland + Quickshell (base-main), CachyOS-LTO kernel, NVIDIA open kernel modules, all-in Quickshell shell, AI agent–friendly, fully tuned for maximum performance / lowest frametime jitter.

## Goals
- Turing+ NVIDIA (RTX 20xx+) only, nvidia-open driver, built at image time for CachyOS-LTO via Clang/ThinLTO
- UKI + systemd-boot (no GRUB), Secure Boot signed (one long-lived MOK key)
- x86-64-v3 minimum hardware target
- `scx_lavd` default scheduler, `tuned` ryven-gaming profile, `kyber` I/O, `cake` + `bbr` networking
- Deep C-state lock for zero wakeup jitter, mitigations=auto, no Plymouth, THP=always, TSC clocksource
- PipeWire tuned for low-latency, OpenAL HRTF, rnnoise noise suppression
- Steam (RPMFusion), Faugus Launcher, Heroic, ProtonPlus, NTSync enabled globally
- Full Hyprland config (VRR=2 fullscreen-only, tear-free desktop, tearing for fullscreen gaming only, minimal animations)
- Quickshell replaces bar/launcher/notifications/OSD; `ryven-control` D-Bus service (three-tier polkit) as single control plane for UI, AI agents, CLI, ujust
- Pi, OpenCode, llama.cpp (CUDA build), t3code preinstalled AI runtime; MCP server over ryven-control
- Zed, Ghostty, Kitty, Neovim, mpv (NVDEC), Firefox + Zen + Brave (VA-API enabled), Vesktop, Bazaar/Flatseal (only preinstalled flatpaks)
- Catppuccin Mocha dark default, switchable themes/icons/cursors/fonts
- Weekly Saturday rebuilds; Renovate pins ublue base digests; verify.sh (prove-it-works) fails the build on drift; OSTree zstd-19 static deltas; no ISOs (OCI only; rebase from an existing bootc system).

## Switch to Ryven
From an existing systemd-boot based bootc system (no GRUB rebase support yet — see `ujust ryven-migrate`):
```
sudo bootc switch ghcr.io/<owner>/ryven-nvidia-open:latest
sudo bootc switch ghcr.io/<owner>/ryven-wl-nvidia-open:latest
```

Enroll Secure Boot MOK key after first boot:
```
ujust enroll-secure-boot-key
```

## Out of scope (explicitly NOT shipped)
- Legacy NVIDIA (pre-Turing / 580xx)
- AMD GPUs
- Laptops/Optimus/battery profiles
- ISOs / installers / VM images
- Auto-updates
- MangoHUD, gamemode, Lutris, Bottles (all opt-in via ujust)
- Plymouth boot splash, coredumps, debug spam
- X11 session on the Hyprland image

Full specification in [`spec/00-RYVEN-SPEC.md`](spec/00-RYVEN-SPEC.md).
