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
# Build toolchain: Clang/LLVM + kernel build tools
dnf5 install -y --skip-unavailable akmods clang lld llvm llvm-devel \
    make openssl kmod elfutils-devel perl flex bison bc dwarves 2>/dev/null || true
# Ensure akmods binary exists
if ! command -v akmods &>/dev/null; then
    dnf5 install -y --skip-unavailable akmods
fi

# Generate signing key if missing (akmods signs built modules).
# kmodgenca fails with empty CN ("string too short" ASN1 error) when run
# non-interactively; use openssl directly to create a valid cert.
install -d -m 0755 /etc/pki/akmods/private /etc/pki/akmods/certs
if [ ! -f /etc/pki/akmods/certs/public_key.der ]; then
    cat > /tmp/kmodgenca.cnf <<'KCNF'
[ req ]
default_bits = 2048
distinguished_name = req_distinguished_name
prompt = no
string_mask = utf8only
x509_extensions = v3_code_sign

[ req_distinguished_name ]
CN = "Ryven Akmods Signing Key"
O = "Ryven"
C = US
ST = CA
L = San Francisco
emailAddress = build@ryven.local

[ v3_code_sign ]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=codeSigning
KCNF
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/pki/akmods/private/private_key.priv \
        -out /etc/pki/akmods/certs/public_key.der \
        -outform DER \
        -config /tmp/kmodgenca.cnf \
        -extensions v3_code_sign 2>/dev/null \
        || echo "WARNING: akmods signing key generation failed; will retry via kmodgenca"
fi
if [ ! -f /etc/pki/akmods/certs/public_key.der ]; then
    kmodgenca -a --force 2>/dev/null || true
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
# Try akmods with --force first (our PATH shim converts runuser -> setpriv), falling back
# to akmodsbuild directly against src.rpms.
for mod in nvidia xone xpadneo openrazer; do
    echo "==> Building akmod: ${mod}"
    SRPM=$(ls /usr/src/akmods/"${mod}"-kmod*.src.rpm 2>/dev/null | head -n1 || echo "")
    if [ -z "${SRPM}" ]; then
        echo "  (no src.rpm found for ${mod}; skipping)"
        continue
    fi
    # Run akmods (the wrapper script) as akmods user via our runuser shim.
    if setpriv --reuid=akmods --regid=akmods --clear-groups --inh-caps=-all -- \
        akmods --force --kernels "${KERNEL_VERSION}" --akmod "${mod}" 2>&1; then
        echo "  ${mod} built via akmods"
    elif setpriv --reuid=akmods --regid=akmods --clear-groups --inh-caps=-all -- \
        akmodsbuild --kernels "${KERNEL_VERSION}" "${SRPM}" 2>&1; then
        echo "  ${mod} built via akmodsbuild"
    else
        echo "ERROR: akmod ${mod} build failed" >&2
        exit 1
    fi
done

# Verify builds succeeded (nvidia is mandatory; others optional per available repos)
for mod in nvidia; do
    if ! ls "/usr/lib/modules/${KERNEL_VERSION}/extra/${mod}"*.ko* >/dev/null 2>&1 \
       && ! ls "/usr/lib/modules/${KERNEL_VERSION}/extra/"*/"${mod}"*.ko* >/dev/null 2>&1; then
        echo "ERROR: kmod ${mod} failed to build for ${KERNEL_VERSION}" >&2
        exit 1
    fi
done
for mod in xone xpadneo openrazer; do
    if ls "/usr/lib/modules/${KERNEL_VERSION}/extra/${mod}"*.ko* >/dev/null 2>&1 \
       || ls "/usr/lib/modules/${KERNEL_VERSION}/extra/"*/"${mod}"*.ko* >/dev/null 2>&1; then
        echo "  kmod ${mod}: built OK"
    else
        echo "  kmod ${mod}: not available (optional); skipping"
    fi
done

# Run depmod for target kernel
depmod -a "${KERNEL_VERSION}"

# Clean up wrapper
rm -rf "${WRAPDIR}"

echo "All akmods built successfully for ${KERNEL_VERSION}"
