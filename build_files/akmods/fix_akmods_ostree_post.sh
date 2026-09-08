#!/usr/bin/env bash
# Patches /usr/sbin/akmods-ostree-post for CachyOS LTO/Clang kmod builds.
# Applied at image build time before any akmods run.
set -euo pipefail

TARGET="/usr/sbin/akmods-ostree-post"
cp -a "${TARGET}" "${TARGET}.orig"

# 1. Replace runuser with setpriv (runuser fails in build container/ostree without a real login session)
sed -i 's|runuser -u akmods --|setpriv --reuid=akmods --regid=akmods --clear-groups --|g' "${TARGET}"

# 2. Inject Clang/ThinLTO compatible build flags for out-of-tree kmods.
#    CachyOS-LTO is built Clang+ThinLTO; nvidia/xone/xpadneo/openrazer need matching toolchain.
cat >> "${TARGET}" <<'PATCH'

# Ryven patch: force Clang + LLVM + no-LTO flags for kmod builds against kernel-cachyos-lto
export CC="/usr/bin/setpriv --reuid=akmods --regid=akmods --clear-groups -- /usr/bin/clang"
export LD="/usr/bin/ld.lld"
export LLVM=1
export KCFLAGS="-fno-lto -fno-split-lto-unit -march=x86-64-v3"
export MAKEFLAGS="-j$(nproc)"
PATCH

chmod +x "${TARGET}"
echo "Patched akmods-ostree-post for CachyOS-LTO/Clang."
