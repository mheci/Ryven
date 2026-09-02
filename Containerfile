# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files

# Prebuilt signed kmods for the OGC kernel (Fedora 44).
# Kernel RPMs come from ghcr.io/opengamingcollective/kernel-packages-fedora:latest-fc44
# (OCI RPM artifact; extracted with skopeo in 05-nvidia-open.sh).
FROM ghcr.io/ublue-os/akmods:ogc-44 AS akmods
FROM ghcr.io/ublue-os/akmods-extra:ogc-44 AS akmods-extra
FROM ghcr.io/ublue-os/akmods-nvidia-open:ogc-44 AS akmods-nvidia

# Base Image
# Track ghcr.io/ublue-os/kinoite-main:latest; digest pinned for reproducible builds (Renovate bumps).
FROM ghcr.io/ublue-os/kinoite-main:latest@sha256:5d1d4fa0ec808a34a879ce03854a93d9d708bdc11a486992ae3435525d363f3b

# /opt must be a real directory so RPM payloads (Zen, Brave) persist.
RUN rm /opt && mkdir /opt

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=akmods,src=/rpms,dst=/tmp/akmods-rpms \
    --mount=type=bind,from=akmods-extra,src=/rpms,dst=/tmp/akmods-extra-rpms \
    --mount=type=bind,from=akmods-nvidia,src=/rpms,dst=/tmp/akmods-nvidia-rpms \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/var/tmp \
    /ctx/build.sh

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
