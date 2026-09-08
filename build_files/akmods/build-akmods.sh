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
dnf5 install -y --skip-unavailable clang lld llvm llvm-devel \
    make openssl kmod elfutils-devel perl flex bison bc dwarves rpm-build \
    ublue-os-akmods-addons 2>/dev/null || true
# Ensure akmods binary exists (from ublue-os-akmods-addons or akmods)
if ! command -v akmods &>/dev/null; then
    dnf5 install -y --skip-unavailable akmods ublue-os-akmods-addons || dnf5 install -y --skip-unavailable akmods
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
# Ensure private key is readable by root (sign-file runs as root during %install)
chmod 0600 /etc/pki/akmods/private/private_key.priv 2>/dev/null || true
chown root:root /etc/pki/akmods/private/private_key.priv 2>/dev/null || true
# Also generate the public_key.x509.cer (DER) counterpart sign-file expects
if [ -f /etc/pki/akmods/certs/public_key.der ] && [ ! -f /etc/pki/akmods/certs/public_key.x509.cer ]; then
    cp /etc/pki/akmods/certs/public_key.der /etc/pki/akmods/certs/public_key.x509.cer
fi
chmod 0644 /etc/pki/akmods/certs/* 2>/dev/null || true

# Out-of-tree kmods against kernel-cachyos-lto (Clang+ThinLTO) are traditionally built
# with the system GCC; CachyOS-LTO exports correct ARCH/COMPILER flags so modules link.
# We only add -march=x86-64-v3 and disable LTO for the out-of-tree kmods.
export KCFLAGS="-fno-lto -fno-split-lto-unit -march=x86-64-v3 -mtune=generic -Wno-error -Wno-incompatible-pointer-types -Wno-implicit-function-declaration -Wno-declaration-after-statement"
export MAKEFLAGS="-j$(nproc)"
# Do NOT globally override CC/CXX/HOSTCC to clang; akmods/kmodtool build user-space
# helpers with the distro compiler and kernel selects its own CC for module builds.

# Run as root (akmods will internally drop to akmods user for compile via runuser,
# but needs root to install the resulting RPM). In containers we shim runuser to
# use setpriv since runuser needs a PAM/login session.
WRAPDIR=$(mktemp -d)
cat > "${WRAPDIR}/runuser" <<'WRAP'
#!/usr/bin/env bash
# Drop-in shim: convert "runuser -u akmods -- <cmd...>" to "setpriv --reuid=akmods --regid=akmods --clear-groups -- <cmd...>"
if [ "$1" = "-u" ] && [ -n "$2" ] && [ "$3" = "--" ]; then
    exec setpriv --reuid="$2" --regid="$2" --clear-groups -- "${@:4}"
fi
# Also handle "runuser -u akmods <cmd...>" (no -- separator)
if [ "$1" = "-u" ] && [ -n "$2" ]; then
    exec setpriv --reuid="$2" --regid="$2" --clear-groups -- "${@:3}"
fi
exec setpriv "$@"
WRAP
chmod +x "${WRAPDIR}/runuser"
export PATH="${WRAPDIR}:${PATH}"

# Ensure akmods user exists (created by akmods package; create if not)
id akmods &>/dev/null || useradd -r -s /sbin/nologin -d /var/lib/akmods -G rpm akmods 2>/dev/null || true
install -d -o akmods -g akmods -m 0755 /var/cache/akmods /var/lib/akmods /tmp/akmodsbuild 2>/dev/null || true
install -d -m 0755 /usr/lib/modules/"${KERNEL_VERSION}"/extra 2>/dev/null || true

# akmods ships with a guard ("Needs to run as root to be able to install rpms") that
# checks / is writable; in container builds / is writable but the check also wants
# `test -w /` to succeed. Make sure root really is root (buildah runs as uid 0) and
# patch the guard directly if it exists.
if [ -f /usr/sbin/akmods ] && grep -q "Needs to run as root" /usr/sbin/akmods 2>/dev/null; then
    echo "Patching /usr/sbin/akmods root/writability guard for container build"
    sed -i 's|Needs to run as root to be able to install rpms|Container build: skip root guard|g' /usr/sbin/akmods
    sed -i 's|if .*id -u.*!=.*0|if false \&\& &|g' /usr/sbin/akmods
    # If it checks test -w /, ensure root owns / (should already) and make / writable
    chmod u+w /
fi
if [ -x /usr/sbin/akmodscheck ]; then
    printf '#!/bin/bash\nexit 0\n' > /usr/sbin/akmodscheck
    chmod +x /usr/sbin/akmodscheck
fi

# brp-kmodsign invokes sign-file as the akmods user (via runuser). Our PATH shim converts
# runuser to setpriv which drops to akmods user; the private key at /etc/pki/akmods/private/
# must be readable by akmods user. Make the key group-owned by akmods and group-readable.
chown root:akmods /etc/pki/akmods/private/private_key.priv 2>/dev/null || true
chmod 0640 /etc/pki/akmods/private/private_key.priv 2>/dev/null || true
chmod 0755 /etc/pki/akmods /etc/pki/akmods/private /etc/pki/akmods/certs 2>/dev/null || true
ls -la /etc/pki/akmods/private/ /etc/pki/akmods/certs/ || true

# Build all required kmods. Run as root (we need to install RPMs); akmods uses runuser
# internally (shimmed to setpriv) to compile as akmods user.
for mod in nvidia xone xpadneo openrazer; do
    echo "==> Building akmod: ${mod}"
    SRPM=$(ls /usr/src/akmods/"${mod}"-kmod*.src.rpm 2>/dev/null | head -n1 || echo "")
    if [ -z "${SRPM}" ]; then
        echo "  (no src.rpm found for ${mod}; skipping)"
        continue
    fi
    # Capture full akmods output to detect real success (it returns 0 even on
    # "[FAILED]" because the post-step says "You can try to rebuild").
    BUILD_LOG=$(mktemp)
    BUILD_OK=0
    set +e
    akmods --force --kernels "${KERNEL_VERSION}" --akmod "${mod}" > "${BUILD_LOG}" 2>&1
    RC=$?
    set -e
    cat "${BUILD_LOG}"
    if [ $RC -eq 0 ] && grep -qE "Building and installing[^]]*\[(OK|SUCCESS)\]" "${BUILD_LOG}"; then
        echo "  ${mod} built via akmods"
        BUILD_OK=1
    elif grep -qiE "Build completed successfully|Installing.*kmod.*\[  OK  \]|\.rpm\.signed" "${BUILD_LOG}"; then
        echo "  ${mod} built via akmods (output-detected)"
        BUILD_OK=1
    else
        # Try akmodsbuild directly
        set +e
        akmodsbuild --kernels "${KERNEL_VERSION}" "${SRPM}" > "${BUILD_LOG}" 2>&1
        RC2=$?
        set -e
        cat "${BUILD_LOG}"
        if [ $RC2 -eq 0 ] && ! grep -qiE "error:|fatal error" "${BUILD_LOG}"; then
            echo "  ${mod} built via akmodsbuild"
            BUILD_OK=1
        fi
    fi
    rm -f "${BUILD_LOG}"

    if [ "${BUILD_OK}" -ne 1 ]; then
        # Dump failure log for debugging
        FAIL_LOG=$(ls /var/cache/akmods/"${mod}"/*failed.log 2>/dev/null | tail -n1 || echo "")
        if [ -n "${FAIL_LOG}" ]; then
            echo "===== ${mod} FAILED LOG (${FAIL_LOG}) ====="
            tail -n 120 "${FAIL_LOG}" 2>/dev/null || true
            echo "===== END FAILED LOG ====="
        fi
        if [ "${mod}" = "nvidia" ]; then
            echo "ERROR: akmod ${mod} build failed (required)" >&2
            exit 1
        else
            echo "WARNING: akmod ${mod} build failed (optional); continuing" >&2
        fi
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
