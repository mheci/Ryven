# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files

# Base Image
# Track ghcr.io/ublue-os/kinoite-main:latest; digest pinned for reproducible builds (Renovate bumps).
FROM ghcr.io/ublue-os/kinoite-main:latest@sha256:fbaeccd397709f311bbade92080b7139c69edcbdb1ae5efa5d89290659fe211c

# /opt must be a real directory so RPM payloads (Zen, Brave) persist.
RUN rm -rf /opt && mkdir -p /opt

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/var/tmp \
    /ctx/build.sh

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
