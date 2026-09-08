# Ryven ryven-wl-nvidia-open: Hyprland + Quickshell + CachyOS-LTO + nvidia-open
FROM ghcr.io/ublue-os/base-main:44
ENV KERNEL_INSTALL_DIR=/dev/null \
    INITRD_POST_UPDATE_DISABLE=true \
    DNF5_DISABLE_POST_TRANSACTION_ACTIONS=true \
    SYSTEMD_OFFLINE=1
LABEL org.opencontainers.image.title="Ryven (Hyprland/Quickshell, nvidia-open)"
LABEL org.opencontainers.image.description="High-performance CachyOS-LTO + nvidia-open Hyprland/Quickshell gaming image"
LABEL org.opencontainers.image.vendor="Ryven"
ARG IMAGE_VARIANT=wl
ENV IMAGE_VARIANT=wl \
    container=oci \
    PRETTY_NAME="Ryven Hyprland (nvidia-open)" \
    NAME=ryven-wl-nvidia-open \
    VARIANT=wl \
    VARIANT_ID=ryven-wl-nvidia-open

# Copy build scripts and system files
COPY build_files /tmp/build_files
COPY system_files/common /
COPY system_files/wl /
COPY skel /tmp/skel

RUN chmod +x /tmp/build_files/*.sh /tmp/build_files/akmods/*.sh

# Set up build environment
RUN /tmp/build_files/setup-cachyos.sh && \
    /tmp/build_files/setup-nvidia.sh && \
    /tmp/build_files/akmods/build-akmods.sh && \
    /tmp/build_files/setup-tuned.sh && \
    /tmp/build_files/setup-codecs.sh && \
    /tmp/build_files/setup-ai.sh && \
    /tmp/build_files/setup-firewall.sh && \
    /tmp/build_files/setup-core-apps.sh && \
    /tmp/build_files/setup-flatpak.sh && \
    /tmp/build_files/setup-themes.sh && \
    /tmp/build_files/build-uki.sh

RUN systemctl enable firstboot-hardware-detect.service ryven-control.service tuned.service greetd.service

RUN /tmp/build_files/verify.sh

RUN dnf clean all && \
    rm -rf /tmp/build_files /var/cache/dnf/* /usr/share/gtk-doc/* /usr/share/doc/* /var/log/* && \
    ostree container commit
