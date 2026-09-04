# Ryven-WL: ublue base-main (no DE) + Hyprland + QuickShell.
# Kernel (CachyOS COPR) and NVIDIA (Negativo17 akmod) resolve at compose time.
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files
COPY system_files_wl /system_files_wl
# The CI host-side Fetch BetterBird step drops the latest tarball into
# _build/betterbird/ in the build context; the image installs it from
# /ctx (install_betterbird in the build script). No network in the
# container.
COPY _build /_build

# Base image: floating ':44' tag = newest ublue F44 build, no digest or
# version lock (zero-maintenance policy). Renovate automerges the tag bump
# when the baseline moves to the next Fedora release.
FROM ghcr.io/ublue-os/base-main:latest

RUN rm -rf /opt && mkdir -p /opt

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/var/tmp \
    /ctx/build-wl.sh

RUN bootc container lint
