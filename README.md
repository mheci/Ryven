# Ryven

Personal [bootc](https://github.com/bootc-dev/bootc) image on **Fedora 44 Kinoite** (KDE Plasma) with the OGC kernel and nvidia-open kmods from Universal Blue.

| | |
| --- | --- |
| Registry | `ghcr.io/mheci/ryven` |
| Default tag | `latest` |
| Base | `ghcr.io/ublue-os/kinoite-main:latest` (digest-pinned) |
| Login | Plasma Login Manager (`plasmalogin`), not SDDM |
| GPU | ublue `akmods-nvidia-open:ogc-44` + OGC kernel |
| Memory | zswap on, zram off |
| Signing | Cosign (`cosign.pub`; secret `SIGNING_SECRET`) |

## Switch

```bash
sudo bootc switch ghcr.io/mheci/ryven:latest
sudo bootc upgrade          # stage only — do not pass --apply
```

Daily CI rebuilds GHCR. It never reboots machines.

## In the image

- NVIDIA open kmods, VA-API (`libva-nvidia-driver` i686+x86_64), Vulkan, 10 GiB shader caches
- Steam, gamescope, ScopeBuddy (`scb`), MangoHud, OBS VkCapture
- Cardwire (`cardwired`), OpenRazer userspace + Polychromatic
- bees timer for Steam Proton `compatdata`
- Kyber I/O scheduler on SCSI/virtio/MMC
- uupd + topgrade (no auto-reboot)
- System Flatpaks: Flatseal, Warehouse, Gear Lever, Bazaar
- greenboot (Rust), sudo-rs (beside sudo)
- Firefox RPM, Zen, Brave Origin, Helium
- Fonts: DejaVu, Droid, Open Sans, Adwaita, Nerd Fonts when packaged

`ujust` recipes: `secure-boot-enroll`, `tpm-luks-unlock`, `scx-select`. Reboot only if you pass `reboot=1`.

Not shipped: CUDA toolkit, Docker, VMs, mesa-freeworld swap, curl installers (pi-agent, opencode, t3code). ISO extra workflows need a GitHub token with `workflow` scope.

## Layout

| Path | Role |
| --- | --- |
| `Containerfile` | `FROM kinoite-main` + `build.sh` |
| `build_files/` | Assemble scripts (numbered) |
| `system_files/` | Overlay into `/` |
| `ryven.env` | Image metadata |
| `disk_config/` | bootc-image-builder / kickstart |

## Local build

```bash
just build
just ostree-rechunk
```
