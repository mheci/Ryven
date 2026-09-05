<p align="center">
  <img src="docs/ryven-logo.png" alt="Ryven" width="160"/>
</p>

<h1 align="center">Ryven</h1>

<p align="center">
  Gaming-ready Fedora desktops that update themselves — pick your desktop, install once, done.
</p>

## Pick your desktop

| Image | Desktop | For you if… |
|---|---|---|
| `ghcr.io/mheci/ryven:latest` | **KDE Plasma** | You want the full, familiar desktop experience |
| `ghcr.io/mheci/ryven-kunzite:latest` | **Hyprland** | You want flashy tiling + keyboard-driven workflow |
| `ghcr.io/mheci/ryven-sericea:latest` | **Sway** | You want a lean, stable tiling setup |

## Install

### Fresh install (USB stick)

Weekly CI publishes an installer ISO for every image — the new Fedora
installer (Anaconda Web UI), maximum-compressed. Download the artifact from
the newest "Build ISOs" run under the repo's Actions tab, then:

```bash
xz -d ryven-YYYYMMDD-installer.iso.xz          # decompress
sudo dd if=ryven-YYYYMMDD-installer.iso of=/dev/sdX bs=16M status=progress
```

Boot the stick, pick your disk and user in the web installer, done.

### Already on a Fedora atomic desktop?

Switch in two commands:

```bash
sudo bootc switch ghcr.io/mheci/ryven:latest
sudo bootc upgrade     # stages the download; reboot when it suits you
```

(Swap the image name for `ryven-kunzite` or `ryven-sericea`.)

Updates land automatically every week, and whenever something in this repo
changes. Your machine never reboots itself — updates wait for you.

## What every image comes with

- **Games just work**: Steam, Proton tweaks for smoother gaming, DLSS
  upscaling and frame generation on NVIDIA out of the box, VRR and tearing
  support, HDR available (never forced).
- **Speed**: a performance-tuned kernel, smarter CPU scheduling for games,
  and a game launcher wrapper: `ujust game cmd='%command%'` in Steam.
- **Clean audio**: no pops, no crackles, no devices falling asleep — audio
  hardware power-saving is fully disabled and the sound stack runs at
  realtime priority.
- **Always-latest browsers**: Firefox, Zen, Brave Origin and BetterBird are
  fetched fresh from the official sites at every build. Firefox and Zen come
  pre-set-up with uBlock Origin, Violentmonkey, Bitwarden, KeePassXC,
  Facebook Container, Cookie AutoDelete and Consent-O-Matic — all
  auto-updating.
- **Passwords & secrets**: the keyring unlocks itself when you log in and
  follows your password changes.
- **The little things**: clipboard history, screenshot annotation + OCR,
  screen recording, KDE Connect, themes (`ujust theme dusk`), English +
  Arabic spell check, podman/distrobox.
- **An AI agent that knows your system**: [Pi](https://pi.dev) comes
  preinstalled — run `pi`, sign in once with `/login`, then just ask it to
  change things. It ships with instructions for this system, so it knows
  what's immutable, which tools exist, and how your bar is built.

## Make it yours — examples per desktop

### Ryven (KDE Plasma)

Everything works through **System Settings**. Extras:

```bash
ujust theme dusk        # switch the built-in dark-blue/dusk look
ujust dlss              # check DLSS status for your games
```

Your KDE Wallet and the system keyring both unlock at login — no password
popups on startup.

### Ryven-Kunzite (Hyprland)

Default keys (Super = Windows key):

```text
Super+Return   terminal          Super+D     app launcher
Super+B        browser           Super+E     file manager
Super+V        clipboard history Print       screenshot (annotate & copy)
Super+Shift+X  lock screen       Super+Shift+R  record screen
```

System defaults live in `/usr/share/hypr/hyprland.conf`. To customize, copy
any of them into `~/.config/hypr/` and edit:

```bash
mkdir -p ~/.config/hypr
cp /usr/share/hypr/hyprland.conf ~/.config/hypr/hyprland.conf
```

The bar is yours to redesign: drop a widget into
`~/.config/quickshell/ryven/extensions/` and it appears — every save
reloads the bar automatically. Want the AI to do it? `ujust customize-bar`
opens Pi with the bar's manual preloaded.

### Ryven-Sericea (Sway)

Default keys (Mod = Windows key):

```text
Mod+Return   terminal (ghostty)  Mod+d     launcher (fuzzel)
Mod+B        browser (firefox)   Mod+V     clipboard history
Mod+Shift+X  lock screen         Print     screenshot (annotate & copy)
```

System defaults: `/etc/sway/config` + `/usr/share/sway/config.d/50-ryven.conf`.
Your own config in `~/.config/sway/config` overrides them:

```bash
mkdir -p ~/.config/sway
cp /etc/sway/config ~/.config/sway/config
```

The bar (workspaces, tray, clock) is yours to redesign: drop a widget into
`~/.config/quickshell/ryven/extensions/` and it appears — every save
reloads the bar automatically. Want the AI to do it? `ujust customize-bar`
opens Pi with the bar's manual preloaded.

## Handy commands (`ujust`)

```bash
ujust game cmd='...'        # launch any game/app with the gaming tuning
ujust dlss                  # DLSS status        ujust smooth-motion on
ujust theme [name=dusk]     # color themes       ujust scx-select
ujust secure-boot-enroll    # enroll signing key ujust brave-hwaccel amd
ujust pi                    # AI coding agent    ujust customize-bar
```

## Good to know

- **CPU**: x86-64-v3 or newer (any Intel Haswell / AMD Excavator era CPU and up).
- **Secure Boot**: turn it off, or sign the kernel yourself — the performance
  kernel and NVIDIA module are not Microsoft-signed.
- **NVIDIA**: the driver is built for your kernel automatically at image build
  time; you don't manage driver updates.

## For builders

```bash
cosign verify --key cosign.pub ghcr.io/mheci/ryven:latest   # check signatures
bash ci/fetch-browsers.sh && just build                     # build locally
```

Every change is built, tested and signed automatically; dependency updates
(Renovate + Dependabot) merge themselves once the build is green.
