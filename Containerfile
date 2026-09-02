# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files

# ublue akmods (OGC, Fedora 44). Bind-mounted into the assemble RUN (Bazzite pattern).
FROM ghcr.io/ublue-os/akmods:ogc-44 AS akmods
FROM ghcr.io/ublue-os/akmods-extra:ogc-44 AS akmods-extra
FROM ghcr.io/ublue-os/akmods-nvidia-open:ogc-44 AS akmods-nvidia

# Base Image
# Track ghcr.io/ublue-os/kinoite-main:latest; digest pinned for reproducible builds (Renovate bumps).
FROM ghcr.io/ublue-os/kinoite-main:latest@sha256:5d1d4fa0ec808a34a879ce03854a93d9d708bdc11a486992ae3435525d363f3b

# /opt must be a real directory so RPM payloads (Zen, Brave) persist.
RUN rm /opt && mkdir /opt

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=akmods,src=/kernel-rpms,dst=/tmp/kernel-rpms \
    --mount=type=bind,from=akmods,src=/rpms,dst=/tmp/akmods-rpms \
    --mount=type=bind,from=akmods-extra,src=/,dst=/tmp/akmods-extra-src \
    --mount=type=bind,from=akmods-nvidia,src=/,dst=/tmp/akmods-nvidia-src \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/var/tmp \
    /ctx/build.sh

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
