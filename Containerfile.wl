# Ryven-WL: ublue base-main (no DE) + Hyprland + QuickShell.
# Kernel (CachyOS COPR) and NVIDIA (RPMFusion akmod) resolve at compose time.
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files
COPY system_files_wl /system_files_wl

# Base image digest-pinned for reproducible builds (Renovate bumps).
FROM ghcr.io/ublue-os/base-main:latest@sha256:79773ec589231a4101f252ba7a2d103caffcf284e483aa49880f3d640e82bf6d

RUN rm -rf /opt && mkdir -p /opt

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/var/tmp \
    /ctx/build-wl.sh

RUN bootc container lint
