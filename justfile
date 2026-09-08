# Ryven local build convenience recipes
default:
    @just --list

build-kde:
    buildah bud -t ryven-nvidia-open:local --build-arg IMAGE_VARIANT=kde -f Containerfile.kde .

build-wl:
    buildah bud -t ryven-wl-nvidia-open:local --build-arg IMAGE_VARIANT=wl -f Containerfile.wl .

verify-kde: build-kde
    podman run --rm --entrypoint /tmp/build_files/verify.sh ryven-nvidia-open:local 2>/dev/null || echo "(run inside container)"

verify-wl: build-wl
    podman run --rm --entrypoint /tmp/build_files/verify.sh ryven-wl-nvidia-open:local 2>/dev/null || echo "(run inside container)"

clean:
    buildah rmi ryven-nvidia-open:local ryven-wl-nvidia-open:local 2>/dev/null || true

shell-kde: build-kde
    podman run --rm -it --entrypoint bash ryven-nvidia-open:local

shell-wl: build-wl
    podman run --rm -it --entrypoint bash ryven-wl-nvidia-open:local
