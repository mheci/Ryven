<p align="center">
  <img src="docs/ryven-logo.png" alt="Ryven" width="160"/>
</p>

<h1 align="center">Ryven</h1>

<p align="center">
  Fedora 44 Kinoite desktop — NVIDIA open, Terra multimedia, CachyOS-inspired frame times.
</p>

`ghcr.io/mheci/ryven:latest` on `ghcr.io/ublue-os/kinoite-main` (Fedora **44** KDE). Plasma Login Manager (`plasmalogin`), not SDDM.

`ghcr.io/mheci/ryven-wl:latest` on `ghcr.io/ublue-os/base-main` (no DE). **Hyprland** + **QuickShell**, greetd/tuigreet + UWSM. Latest Hyprland stack from COPR `nett00n/hyprland` at compose time. Master layout, tearing + `preferred` (max res/refresh) on all monitors. Clipboard: wl-clipboard, cliphist, wl-clip-persist. Notifications: dunst. Portals: xdg-desktop-portal-hyprland. Screenshots: grim/slurp/satty/hyprshot. Phone: KDE Connect. NVIDIA: `NVD_BACKEND=direct`, GBM nvidia-drm — not `LIBVA_DRIVER_NAME=nvidia`.

`ghcr.io/mheci/ryven-sericea:latest` on `ghcr.io/ublue-os/base-main` + **Sway** (ublue `sericea-main` is deprecated). Same NVIDIA/gaming/agent stack. Tearing + preferred outputs, dunst, cliphist, wl-clip-persist (built from source if no RPM), KDE Connect, xdg-desktop-portal-wlr, greetd. GPU: ublue `akmods` / `akmods-extra` / `akmods-nvidia-open` (`ogc-44`) plus OGC `kernel-packages-fedora:latest-fc44`. **zswap on**, **zram off**. ISO is weekly after the scheduled OCI build.

## Switch

```bash
sudo bootc switch ghcr.io/mheci/ryven:latest
# or: ghcr.io/mheci/ryven-wl:latest
# or: ghcr.io/mheci/ryven-sericea:latest
sudo bootc upgrade          # stage only — do not pass --apply
```

Weekly CI rebuilds GHCR (Sunday 06:00 UTC). ISO follows a successful scheduled image. Hosts never auto-reboot on updates. greenboot `redboot-auto-reboot` stays enabled when the unit exists.

## Desktop and games

- NVIDIA VA-API: `libva-nvidia-driver` x86_64 + i686 (`NVD_BACKEND=direct`)
- 10 GiB shader caches
- Steam RPM, **proton-cachyos** (SLR), NTSync 0666, Proton Wayland + HDR
- `terra-gamescope`, ScopeBuddy (`scb`), MangoHud, Heroic, ProtonPlus, Helium, GPU Screen Recorder, Polychromatic
- **scx-scheds** + **scx-tools** / `scx_loader` with lavd `--performance`
- **bpftune-gaming** and **ananicy-cpp** + CachyOS rules
- beesd@UUID on host btrfs, NVMe kyber / HDD bfq
- **mpv**, Terra ffmpeg, **t3code**, **zed**, ghostty-tip
- uupd + topgrade (no auto-reboot)
- First-boot Flatpaks on `/var`: Flatseal, Warehouse, Gear Lever, Bazaar

`ujust`: `secure-boot-enroll`, `tpm-luks-unlock`, `scx-select`. Reboot only with `reboot=1`.

## Not in the image

CUDA, Docker/VMs, `terra-release-nvidia`, mesa-freeworld swap, cardwire, v4l2loopback, `curl | sh`.

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
