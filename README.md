# Ryven

Personal [bootc](https://github.com/bootc-dev/bootc) image. Derived from [`ghcr.io/ublue-os/base-main:latest`](https://github.com/ublue-os/main). Built, rechunked, pushed, and cosign-signed by GitHub Actions.

| | |
| --- | --- |
| Registry | `ghcr.io/mheci/ryven` |
| OCI title | `Ryven` |
| Default tag | `latest` |
| Base | `ghcr.io/ublue-os/base-main:latest` |
| Build | `.github/workflows/build.yml` (push to `main`, daily `05 10 * * *` UTC, `workflow_dispatch`) |
| Signing | Cosign; public key `cosign.pub`; private key is Actions secret `SIGNING_SECRET` |

## Switch (bootc host)

```bash
sudo bootc switch ghcr.io/mheci/ryven:latest
```

Verify the signature against `cosign.pub` before trusting a new digest.

## Layout

| Path | Role |
| --- | --- |
| `Containerfile` | Image definition (`FROM` + `build.sh`) |
| `build_files/build.sh` | Package installs and image customizations |
| `system_files/` | Overlay into `/` (`etc/`, `usr/`) |
| `ryven.env` | `IMAGE_NAME=Ryven` and related build metadata |
| `disk_config/` | bootc-image-builder configs; kickstart targets `ghcr.io/mheci/ryven:latest` |
| `.github/workflows/build.yml` | OCI build, rechunk, GHCR push, cosign |
| `.github/workflows/build-disk.yml` | Optional qcow2 / Anaconda ISO |

## Local build

Requires `just`, `podman`, `jq`.

```bash
just build          # tags localhost-usable ref `ryven:latest` (OCI lowercase)
just ostree-rechunk
```

`IMAGE_NAME` in `ryven.env` is `Ryven`. The Justfile lowercases it for Podman/GHCR refs. OCI image names cannot contain uppercase letters.

## Disk images

`build-disk.yml` is manual (`workflow_dispatch`). ISO kickstarts rebase the installed system to `ghcr.io/mheci/ryven:latest`. S3 upload is optional (see Actions secrets `S3_*`).

## Just recipes

See `Justfile`. Common: `just build`, `just ostree-rechunk`, `just build-qcow2`, `just lint`, `just format`.
