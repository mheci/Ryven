<p align="center">
  <img src="docs/ryven-logo.png" alt="Ryven" width="160"/>
</p>

<h1 align="center">Ryven</h1>

<p align="center">
  Fedora 44 Kinoite desktop — CachyOS LTO kernel, NVIDIA open, Terra multimedia.
</p>

`ghcr.io/mheci/ryven:latest` on `ghcr.io/ublue-os/kinoite-main` (Fedora **44** KDE). Plasma Login Manager (`plasmalogin`), not SDDM. Kernel: CachyOS LLVM-ThinLTO (`kernel-cachyos-lto`, BORE scheduler) from COPR.

`ghcr.io/mheci/ryven-wl:latest` on `ghcr.io/ublue-os/base-main` (no DE). **Hyprland** + **QuickShell**, greetd/tuigreet + UWSM. Latest Hyprland stack from COPR `nett00n/hyprland` at compose time. Master layout, tearing + `preferred` (max res/refresh) on all monitors. Clipboard: wl-clipboard, cliphist, wl-clip-persist. Notifications: dunst. Portals: xdg-desktop-portal-hyprland. Screenshots: grim/slurp/satty/hyprshot. Phone: KDE Connect. NVIDIA: `NVD_BACKEND=direct`, GBM nvidia-drm — not `LIBVA_DRIVER_NAME=nvidia`. Kernel: CachyOS LLVM-ThinLTO, same as ryven.

`ghcr.io/mheci/ryven-sericea:latest` on `ghcr.io/ublue-os/base-main` + **Sway** (ublue `sericea-main` is deprecated). Same NVIDIA/gaming/agent stack. Tearing + preferred outputs, dunst, cliphist, wl-clip-persist (built from source if no RPM), KDE Connect, xdg-desktop-portal-wlr, greetd. Kernel: CachyOS LLVM-ThinLTO; NVIDIA module compiled from RPMFusion `akmod-nvidia` at image build time. **zswap on**, **zram off**. ISO is weekly after the scheduled OCI build.

## Switch

```bash
sudo bootc switch ghcr.io/mheci/ryven:latest
# or: ghcr.io/mheci/ryven-wl:latest
# or: ghcr.io/mheci/ryven-sericea:latest
sudo bootc upgrade          # stage only — do not pass --apply
```

Weekly CI rebuilds GHCR (Sunday 06:00 UTC). ISO follows a successful scheduled image. Hosts never auto-reboot on updates. greenboot `redboot-auto-reboot` stays enabled when the unit exists.

## Hardware notes

- CPU: the CachyOS kernel requires **x86_64_v3**. x86_64_v2 machines cannot boot these images.
- Secure Boot: the CachyOS kernel and the locally compiled NVIDIA module are **unsigned**. Keep Secure Boot **disabled**, or sign the kernel and modules with your own Machine Owner Key and enroll it. `ujust secure-boot-enroll` only enrolls the Universal Blue key, which alone is no longer sufficient.
- NVIDIA: kernel module is compiled from RPMFusion `akmod-nvidia` at image build time; no prebuilt NVIDIA modules ship (per CachyOS COPR policy).

## Desktop and games

- NVIDIA VA-API: `libva-nvidia-driver` x86_64 + i686 (`NVD_BACKEND=direct`)
- 10 GiB shader caches
- Steam RPM, **proton-cachyos** (SLR), NTSync 0666, Proton Wayland + HDR
- `terra-gamescope`, ScopeBuddy (`scb`), MangoHud, Heroic, ProtonPlus, Helium, GPU Screen Recorder, Polychromatic
- **scx-scheds** + **scx-tools** / `scx_loader` with lavd `--performance`, plus **scx-manager** GUI (CachyOS addons COPR)
- **bpftune-gaming** and **ananicy-cpp** + CachyOS rules
- beesd@UUID on host btrfs, NVMe kyber / HDD bfq
- **mpv**, Terra ffmpeg, **t3code**, **zed**, ghostty-tip
- uupd + topgrade (no auto-reboot)
- First-boot Flatpaks on `/var`: Flatseal, Warehouse, Gear Lever, Bazaar

`ujust`: `secure-boot-enroll`, `tpm-luks-unlock`, `scx-select`. Reboot only with `reboot=1`.

## Minimum functionality (all images)

- **Clipboard**: manager + history persistence — wl/sericea: wl-clipboard + cliphist +
  wl-clip-persist (survives reboots); ryven: KRunner paste clipboard history.
- **OCR screenshotting**: wl/sericea: `screenshot-ocr` / `screenshot-ocr --region`
  (grim + slurp + tesseract, eng/ara, text to stdout and clipboard); ryven: Spectacle's
  built-in OCR (tesseract installed for it).
- **Notifications**: dunst (wl/sericea), Plasma KNotify (ryven).
- **KDE Connect**: preinstalled and firewall-open OOTB (mdns discovery + `1714/tcp`
  through firewalld, applied before firewalld starts; pair via `kdeconnect-cli`).
- **polkit**: daemon on all images; agent OOTB — `hyprpolkitagent` (wl), `polkit-kde`
  (ryven), portal-based agent on sericea via xdg-desktop-portal.
- **KIO / GVFS**: ryven: kio-fuse + kio-extras + kio-gdrive; wl/sericea: gvfs +
  gvfs-mtp + gvfs-smb + gvfs-gphoto2 (phone/camera + SMB file access).
- **yazi**: from Terra (not in Fedora 44 repos).
- **`vm.max_map_count=2147483642`** (MAX_INT − 5, the SteamOS default per the
  Arch gaming wiki): `/etc/sysctl.d/90-ryven-max-map-count.conf`, survives bootc updates.
- **Gaming performance** (Arch wiki `Gaming#Improving_performance`, all images):
  - `tsc=reliable clocksource=tsc` kernel args (x86_64_v3 ⇒ invariant TSC, so safe)
  - response-time sysctl/sysfs set via `/etc/tmpfiles.d/ryven-gaming-response-time.conf`
    (proactive compaction off, watermark boost 1, 1 GiB min_free_kbytes, watermark
    scale 500, swappiness 10, MGLRU=5, zone reclaim off, page_lock_unfairness 1,
    CFS slice/migration tuning — inert under scx_lavd, active on the CFS fallback)
  - **Huge pages on for Proton**: THP `always` (enabled/shmem/defrag) — the
    wiki's "never" is deliberately overridden for Proton max performance — plus a
    reserved 2 GiB pool (1024 × 2 MiB, `kargs.d/50-hugepages.toml`) so game
    MAP_HUGETLB allocations hit preallocated pages
  - **BBR** congestion control (`net.ipv4.tcp_congestion_control=bbr`, loads
    tcp_bbr) for downloads/updates/streaming on high-BDP links, paired with the
    fair-queue qdisc BBR is designed to run beside
  - `net.core.default_qdisc=fq_codel` (network buffer bloat)
  - CachyOS-style PCI latency timers at boot (`ryven-pci-latency.service`,
    20 cycles all devices / 0 root bridge / 80 audio)
  - `/etc/drirc` `vblank_mode=0` (DRI input latency; inert for the NVIDIA driver)
  - **falcond** (enabled): per-game performance daemon — detects the running
    game, applies its profile (scheduler/power/vcache/scripts), reverts on
    exit. OOTB config in `/etc/falcond/config.conf` (scx_loader still owns the
    boot-time scheduler; per-game profiles may switch per title), profiles from
    `falcond-profiles`, template at `/usr/share/falcond/profiles/user/` —
    `ujust falcond-profile name=<game-exe>` scaffolds one. **GameMode is
    deliberately NOT installed** (the packages `Conflicts`; falcond replaces it).
  - `ujust game cmd='steam' [nice=-4]`: runs a game with `LD_BIND_NOW=1` + nice −4
    (per-invocation on purpose — the wiki warns against a global `LD_BIND_NOW`)
  - already in the image: scx_lavd `--performance` (the wiki-recommended scheduler),
    zswap on / zram off, BFQ for HDD storage (NVMe stays on the documented kyber)
  - not applicable from the section: SMT (BIOS-level; the wiki says disable there),
    ACO (AMD-only, these images are NVIDIA), schedtoold (AUR-only; scx_lavd
    already prioritizes game tasks)
- **Spell check**: hunspell + aspell + gspell with `en`, `en-US`, `en-GB` (F44's full
  English set) and Arabic (`hunspell-ar`; F44 has no `aspell-ar`).
- **DNS**: opportunistic DNS encryption OOTB with Cloudflare — systemd-resolved is the
  NetworkManager DNS backend and Cloudflare (1.1.1.1 / 2606:4700:4700::1111 / family-2)
  is preconfigured globally with `DNSOverTLS=yes`: local (DHCP) DNS still answers local
  names first, everything else resolves via Cloudflare over TLS, and if the encrypted
  path is blocked resolved falls back to plain for the same servers.
- **c-ares** runtime for the agentic toolchain.
- **nohang** (Terra, enabled at boot): PSI-based low-memory handler — kills the
  offending process before an OOM freeze; keeps the desktop responsive during
  game streaming / heavy agentic workloads (`psi-top`, `psi2log` shipped for
  diagnosis).
- **vicinae** (Terra, starts at login): high-performance native game launcher.
- **lact** (Terra, `lactd` enabled): GPU monitoring/configuration tool.
- **openrazer** (Terra userspace + `openrazerd`): Razer device daemon over the
  mainline `razer_*` drivers (the openrazer kmod is not buildable for the
  CachyOS kernel, so it is intentionally not part of the akmods build).
- **SELinux gaming**: `selinuxuser_execmod`, `selinuxuser_execstack`,
  `selinuxuser_execheap` (+ `domain_kernel_load_modules` for the akmod nvidia
  module) applied at compose via `semanage boolean -m --on`, `setsebool -P`
  fallback.

## Themes

- **Ryven** (default): deep navy/slate — coolors `0d1b2a-1b263b-415a77-778da9-e0e1dd`.
- **Ryven Dusk**: warm indigo/mauve — coolors `22223b-4a4e69-9a8c98-c9ada7-f2e9e4`.

KDE ships both as color schemes (+ konsole profiles); wl/sericea ship navy as the default
(hyprland borders, hyprlock, QuickShell panel, dunst / swaylock). Token source of truth:
`/usr/share/ryven/themes/{navy,dusk}.json`. Switch: `ujust theme` (lists) /
`ujust theme name=dusk` — KDE applies the scheme live; wl/sericea write the token read by the
shell on restart.

## Secrets & keyring

- **ryven-wl / ryven-sericea — oo7** replaces gnome-keyring as the D-Bus Secret Service
  (`org.freedesktop.secrets`). Fedora 44 repos ship only `oo7-cli` (no daemon/PAM), so the
  full stack is source-built at compose from a pinned tag: `oo7-daemon` (per-session,
  D-Bus-activated user unit), `oo7-cli`, `cargo-credential-oo7`, the `pam_oo7.so` PAM module,
  and `oo7-portal` (XDG portal backend, `UseIn=hyprland,sway`).
- **Auto-unlock + password sync** (all images, first-boot oneshot, stamped + idempotent):
  the login password unlocks the keyring at the greeter, and on wl/sericea the login keyring
  follows `passwd` (`/etc/pam.d/passwd` picks up `password optional pam_oo7.so`). On KDE the
  same oneshot wires `pam-kwallet` (`pam_kwallet5.so`, `kwalletd=/usr/bin/ksecretd`) to
  auto-unlock the default KDE Wallet — its password must equal the user password, set once at
  first use; kwallet-pam has no password module, so there is no KDE password sync.
- Manual control on wl/sericea: `oo7-cli unlock -s`, `oo7-cli lock`. Cargo: add
  `global-credential-providers = ["cargo-credential-oo7"]` to `~/.config/cargo/config.toml`
  (git already uses `git-credential-libsecret` against the Secret Service).

## Not in the image

CUDA toolkit (the driver's CUDA runtime libs ship with the driver), Docker/VMs,
`terra-release-nvidia`, mesa-freeworld swap, cardwire, v4l2loopback, `curl | sh`,
GameMode (conflicts with falcond, which provides the same role).

```bash
just build
CONTAINERFILE=Containerfile.wl just build ryven-wl
CONTAINERFILE=Containerfile.sericea just build ryven-sericea
just ostree-rechunk
```

## Verify

```bash
cosign verify --key cosign.pub ghcr.io/mheci/ryven:latest
gh attestation verify oci://ghcr.io/mheci/ryven:latest --repo mheci/Ryven
```

CI: ShellCheck, Hadolint, CodeQL (Actions), container-structure-test, `bootc container lint`, Grype (informational). Each image has its own Actions workflow (`Build ryven`, `Build ryven-wl`, `Build ryven-sericea`) with no shared concurrency group so a failed or queued sibling cannot cancel or block publish. Pushes to `main` sign with Cosign (OIDC keyless + optional `SIGNING_SECRET`) and attach SLSA provenance. Dependabot and Renovate bump Actions, Containerfile, and digest pins. Secret scanning and push protection are enabled on the GitHub repo.
