<p align="center">
  <img src="docs/ryven-logo.png" alt="Ryven" width="160"/>
</p>

<h1 align="center">Ryven</h1>

<p align="center">
  Fedora 44 Kinoite desktop — NVIDIA open, Terra multimedia, CachyOS-inspired frame times.
</p>

<p align="center">
  <img src="docs/desktop-preview.png" alt="Ryven Plasma desktop (branded preview)" width="720"/>
</p>

| | |
| --- | --- |
| Image | `ghcr.io/mheci/ryven:latest` |
| Base | `ghcr.io/ublue-os/kinoite-main` (Fedora **44** KDE) |
| Login | Plasma Login Manager (`plasmalogin`), not SDDM |
| GPU | ublue `akmods-nvidia-open` + OGC kernel |
| Memory | **zswap on**, **zram off** |
| Default look | `org.ryven.desktop` + wallpaper **10** |
| ISO | monthly `ryven-YYYYMMDD-amd64.iso` (Actions artifact) |

This sandbox cannot boot the OCI image (no VM). The preview above is the Ryven theme (logo 10 / wallpaper palette), not a live `bootc` session.

## Switch

```bash
sudo bootc switch ghcr.io/mheci/ryven:latest
sudo bootc upgrade          # stage only — do not pass --apply
```

Daily CI rebuilds GHCR. Monthly ISO is `17 5 1 * *` UTC. Hosts never auto-reboot.

## Desktop and games

- NVIDIA VA-API: `libva-nvidia-driver` x86_64 + i686 (`NVD_BACKEND=direct`, no global `LIBVA_DRIVER_NAME`)
- 10 GiB shader caches
- Steam RPM, **proton-cachyos** (SLR) under `/usr/share/steam/compatibilitytools.d`, **NTSync** (`/dev/ntsync` mode 0666 + `uaccess`)
- `terra-gamescope`, ScopeBuddy (`scb`), MangoHud, Heroic, ProtonPlus
- **scx-scheds-nightly** with **`scx_lavd` enabled** (`/etc/default/scx`)
- **bpftune-gaming** and **ananicy-cpp** + CachyOS rules, enabled
- Cardwire (`cardwired`), bees on Proton `compatdata`, Kyber I/O
- **mpv-nightly**, Terra ffmpeg/GStreamer, ffmpegthumbnailer
- **t3code-nightly**, Zed, Ghostty, mise/bun/deno
- uupd + topgrade (no auto-reboot)
- System Flatpaks only: Flatseal, Warehouse, Gear Lever, Bazaar

`ujust` : `secure-boot-enroll`, `tpm-luks-unlock`, `scx-select`. Reboot only with `reboot=1`.

## CachyOS settings we took

High `vm.max_map_count`, dirty-byte caps, `split_lock_mitigate=0`, HPET in `audio`, NTSync udev, proton-cachyos, ananicy rules, scx_lavd.

We did **not** take Cachy zram, `vm.swappiness=100`, or NVIDIA runtime PM (stutter risk on a desktop where power is irrelevant).

## Not in the image

CUDA, Docker/VMs, `terra-release-nvidia`, mesa-freeworld swap, `ffmpegthumbs`, Game Mode / Decky, `uutils-coreutils-replace`, other DEs, `curl | sh`.

## Layout

| Path | Role |
| --- | --- |
| `Containerfile` | `FROM kinoite-main` + `build.sh` |
| `build_files/` | Numbered assemble scripts |
| `system_files/` | Overlay into `/` |
| `disk_config/` | Anaconda kickstart / disk |
| `docs/` | Logo and README art |

```bash
just build
just ostree-rechunk
```
