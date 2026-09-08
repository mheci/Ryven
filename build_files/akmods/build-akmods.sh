#!/usr/bin/env bash
# Build all required akmods against the currently installed CachyOS-LTO kernel.
# Uses Clang/LLVM/ThinLTO-compatible flags directly (no patching of system scripts).
set -euo pipefail

KERNEL_VERSION="$(rpm -q kernel-cachyos-lto --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | head -n1)"
echo "Building akmods for kernel: ${KERNEL_VERSION}"

# Ensure kernel-devel-matched and build deps are installed
if ! rpm -q "kernel-cachyos-lto-devel-matched" &>/dev/null; then
    dnf5 install -y --skip-unavailable kernel-cachyos-lto-devel-matched
fi
# Ensure akmods binary exists
if ! command -v akmods &>/dev/null; then
    dnf5 install -y --skip-unavailable akmods
fi

# Generate signing key if missing
if [ ! -f /etc/pki/akmods/certs/public_key.der ]; then
    kmodgenca -a --force
fi

# Clang/ThinLTO-compatible build flags for CachyOS-LTO kernel (Clang+ThinLTO, 1000Hz, x86-64-v3).
# Use setpriv instead of runuser (works in build container without login session).
export CC="/usr/bin/clang"
export CXX="/usr/bin/clang++"
export LD="/usr/bin/ld.lld"
export AR="/usr/bin/llvm-ar"
export NM="/usr/bin/llvm-nm"
export STRIP="/usr/bin/llvm-strip"
export OBJCOPY="/usr/bin/llvm-objcopy"
export OBJDUMP="/usr/bin/llvm-objdump"
export READELF="/usr/bin/llvm-readelf"
export HOSTCC="/usr/bin/clang"
export HOSTCXX="/usr/bin/clang++"
export LLVM=1
export LLVM_IAS=1
export KERNEL_CC=clang
# Disable LTO for kmods (can't link against LTO'd kernel objects); target x86-64-v3
export KCFLAGS="-fno-lto -fno-split-lto-unit -march=x86-64-v3 -mtune=generic -Wno-error"
export MAKEFLAGS="-j$(nproc)"

# akmods internally calls runuser; override it with setpriv via a wrapper injected in PATH
WRAPDIR=$(mktemp -d)
cat > "${WRAPDIR}/runuser" <<'WRAP'
#!/usr/bin/env bash
# Drop-in shim: convert "runuser -u akmods -- <cmd...>" to "setpriv --reuid=akmods --regid=akmods --clear-groups -- <cmd...>"
if [ "$1" = "-u" ] && [ -n "$2" ] && [ "$3" = "--" ]; then
    exec setpriv --reuid="$2" --regid="$2" --clear-groups -- "${@:4}"
fi
exec setpriv "$@"
WRAP
chmod +x "${WRAPDIR}/runuser"
export PATH="${WRAPDIR}:${PATH}"

# Ensure akmods user exists (created by akmods package; create if not)
id akmods &>/dev/null || useradd -r -s /sbin/nologin -d /var/lib/akmods -G rpm akmods 2>/dev/null || true
install -d -o akmods -g akmods -m 0755 /var/cache/akmods /var/lib/akmods /tmp/akmodsbuild 2>/dev/null || true

# Build all required kmods: akmods refuses to run as root in container builds.
# We already install akmod-nvidia with --setopt=tsflags=notriggers to skip its %post.
# Run akmodsbuild (the direct builder) as akmods user with Clang/LLVM env.
for mod in nvidia xone xpadneo openrazer; do
    echo "==> Building akmod: ${mod}"
    setpriv --reuid=akmods --regid=akmods --clear-groups --inh-caps=-all -- \
        akmodsbuild --kernels "${KERNEL_VERSION}" /usr/src/akmods/"${mod}"-kmod*.src.rpm \
        || (echo "ERROR: akmod ${mod} build failed"; exit 1)
done

# Verify builds succeeded
for mod in nvidia xone xpadneo openrazer; do
    if ! ls "/usr/lib/modules/${KERNEL_VERSION}/extra/${mod}"*.ko* >/dev/null 2>&1; then
        echo "ERROR: kmod ${mod} failed to build for ${KERNEL_VERSION}" >&2
        exit 1
    fi
done

# Run depmod for target kernel
depmod -a "${KERNEL_VERSION}"

# Clean up wrapper
rm -rf "${WRAPDIR}"

echo "All akmods built successfully for ${KERNEL_VERSION}"
