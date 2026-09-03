# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files
# The CI host-side Fetch BetterBird step drops the latest tarball into
# _build/betterbird/ in the build context; the image installs it from
# /ctx (install_betterbird in the build script). No network in the
# container.
COPY _build /_build

# Base Image
# Floating ':44' tag: always pulls the newest ublue F44 build, no digest or
# version lock (zero-maintenance policy). Renovate automerges the tag bump
# when the baseline moves to the next Fedora release.
FROM ghcr.io/ublue-os/kinoite-main:44

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
