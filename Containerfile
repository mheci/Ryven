# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files
# The CI host-side "Fetch browsers" step drops the always-latest payloads
# (BetterBird, Firefox, Zen, Brave Origin) into _build/ in the build
# context; the image installs them from /ctx (compose.sh installers).
COPY _build /_build

# Base Image
# Floating ':latest' tag: always pulls the newest ublue build, no digest or
# version lock (zero-maintenance policy).
FROM ghcr.io/ublue-os/kinoite-main:latest

# /opt must be a real directory so RPM payloads (Brave) persist.
RUN rm -rf /opt && mkdir -p /opt

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/var/tmp \
    --mount=type=secret,id=GITHUB_TOKEN \
    /ctx/build.sh

### LINTING
## Verify final image and contents are correct.
RUN --mount=type=tmpfs,target=/run --network=none bootc container lint
