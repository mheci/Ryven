#!/usr/bin/env bash
# Basic retry helper for transient network failures
try() { for i in 1 2 3; do "$@" && return 0; echo "  retry $i/3 ($*)"; sleep 5; done; return 1; }
# Install AI runtime: Pi, OpenCode, llama.cpp (CUDA build), t3code, ryven-control, MCP server.
set -euo pipefail
shopt -s nullglob

echo "Installing Node.js (for Pi)..."
dnf5 install -y --skip-unavailable --setopt=strict=0 nodejs npm || true

echo "Installing Pi coding agent (best-effort)..."
npm install -g --ignore-scripts --prefix /usr/local @earendil-works/pi-coding-agent 2>&1 || echo "WARNING: Pi npm install failed; skipping"

echo "Installing OpenCode (Go binary, best-effort)..."
curl -fsSL https://opencode.ai/install | bash -s -- --dir /usr/local 2>&1 || echo "WARNING: OpenCode install failed; skipping"

echo "Installing t3code from Terra..."
if ! dnf5 install -y --skip-unavailable --setopt=strict=0 t3code 2>/dev/null; then
    echo "t3code not in Terra; trying COPR..."
    (dnf5 copr enable -y ponesicek/t3code-nightly-bin 2>/dev/null && dnf5 install -y --skip-unavailable --setopt=strict=0 t3code 2>/dev/null) \
        || echo "WARNING: t3code unavailable; continuing"
fi

echo "Building llama.cpp from source with CUDA/x86-64-v3 (best-effort)..."
# Build dependencies (best-effort; CUDA stack may be large; install what we can)
dnf5 install -y --skip-unavailable --setopt=strict=0 --setopt install_weak_deps=False \
    cmake gcc-c++ git cuda-nvcc cuda-cudart-devel 2>/dev/null || true
TMPDIR=$(mktemp -d)
if git clone --depth 1 https://github.com/ggml-org/llama.cpp "${TMPDIR}" 2>/dev/null; then
    if cmake -S "${TMPDIR}" -B "${TMPDIR}/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_CUDA=ON \
        -DGGML_NATIVE=OFF \
        -DCMAKE_C_FLAGS="-march=x86-64-v3" \
        -DCMAKE_CXX_FLAGS="-march=x86-64-v3" \
        -DLLAMA_BUILD_SERVER=ON \
        -DLLAMA_BUILD_CLI=ON 2>/dev/null; then
        cmake --build "${TMPDIR}/build" -j"$(nproc)" --target llama-cli llama-server llama-gguf-split llama-perplexity 2>/dev/null || true
        install -m 0755 "${TMPDIR}/build/bin/llama-"* /usr/bin/ 2>/dev/null || echo "  (llama.cpp binaries not installed)"
    else
        echo "WARNING: llama.cpp cmake configure failed (likely CUDA headers missing); skipping source build"
    fi
else
    echo "WARNING: llama.cpp git clone failed (network); skipping source build"
fi
rm -rf "${TMPDIR}"

echo "Installing ryven-control daemon + MCP server..."
# Systemd unit for llama-server (opt-in, user unit)
[ -f system_files/wl/usr/lib/systemd/user/llama-server.service ] && cp system_files/wl/usr/lib/systemd/user/llama-server.service /usr/lib/systemd/user/ 2>/dev/null || true
# Copy ryven-control systemd unit
[ -f system_files/common/usr/lib/systemd/system/ryven-control.service ] && cp system_files/common/usr/lib/systemd/system/ryven-control.service /usr/lib/systemd/system/ 2>/dev/null || true
[ -f system_files/common/usr/lib/systemd/system/firstboot-hardware-detect.service ] && cp system_files/common/usr/lib/systemd/system/firstboot-hardware-detect.service /usr/lib/systemd/system/ 2>/dev/null || true

echo "AI runtime installed (best-effort):"
command -v pi >/dev/null && pi --version || echo "  pi: not installed"
command -v opencode >/dev/null && opencode --version || echo "  opencode: not installed"
command -v llama-cli >/dev/null && llama-cli --version || echo "  llama-cli: not installed"
command -v t3 >/dev/null && t3 --version || echo "  t3: not installed"
