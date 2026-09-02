# Ryven-WL: ublue base-main (no DE) + Hyprland + QuickShell.
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files
COPY system_files_wl /system_files_wl

FROM ghcr.io/ublue-os/akmods:ogc-44 AS akmods
FROM ghcr.io/ublue-os/akmods-extra:ogc-44 AS akmods-extra
FROM ghcr.io/ublue-os/akmods-nvidia-open:ogc-44 AS akmods-nvidia

# Track ghcr.io/ublue-os/base-main:latest; digest-pin later via Renovate.
FROM ghcr.io/ublue-os/base-main:latest

RUN rm /opt && mkdir /opt

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=akmods,src=/rpms,dst=/tmp/akmods-rpms \
    --mount=type=bind,from=akmods-extra,src=/rpms,dst=/tmp/akmods-extra-rpms \
    --mount=type=bind,from=akmods-nvidia,src=/rpms,dst=/tmp/akmods-nvidia-rpms \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/var/tmp \
    /ctx/build-wl.sh

RUN bootc container lint
