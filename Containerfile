# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files

# Base Image
# Track ghcr.io/ublue-os/kinoite-main:latest; digest pinned for reproducible builds (Renovate bumps).
FROM ghcr.io/ublue-os/kinoite-main:latest@sha256:5d1d4fa0ec808a34a879ce03854a93d9d708bdc11a486992ae3435525d363f3b

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
