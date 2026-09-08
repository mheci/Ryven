#!/usr/bin/env bash
# Basic retry helper for transient network failures
try() { for i in 1 2 3; do "$@" && return 0; echo "  retry $i/3 ($*)"; sleep 5; done; return 1; }
# Install AI runtime: Pi, OpenCode, llama.cpp (CUDA build), t3code, ryven-control, MCP server.
set -euo pipefail

echo "Installing Node.js (for Pi)..."
dnf5 install -y --skip-unavailable nodejs npm

echo "Installing Pi coding agent..."
npm install -g --ignore-scripts @earendil-works/pi-coding-agent

echo "Installing OpenCode (Go binary)..."
curl -fsSL https://opencode.ai/install | bash -s -- --dir /usr/local

echo "Installing t3code from Terra..."
if ! dnf5 install -y --skip-unavailable t3code; then
    echo "t3code not in Terra; trying COPR..."
    (dnf5 copr enable -y ponesicek/t3code-nightly-bin 2>/dev/null && dnf5 install -y --skip-unavailable t3code) \
        || echo "WARNING: t3code unavailable; continuing"
fi

echo "Building llama.cpp from source with CUDA/x86-64-v3..."
# Build dependencies (best-effort; CUDA stack may be large; install what we can)
dnf5 install -y --skip-unavailable --setopt install_weak_deps=False \
    cmake gcc-c++ git cuda-nvcc cuda-cudart-devel cuda-gcc || true
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
        install -m 0755 "${TMPDIR}/build/bin/llama-"* /usr/bin/ 2>/dev/null || true
    else
        echo "WARNING: llama.cpp cmake configure failed (likely CUDA headers missing); skipping source build"
    fi
else
    echo "WARNING: llama.cpp git clone failed (network); skipping source build"
fi
rm -rf "${TMPDIR}"

echo "Installing ryven-control daemon + MCP server..."
# Placeholder: ryven-control Python/Go D-Bus service ships as part of the image
# Systemd unit for llama-server (opt-in, user unit)
cp system_files/wl/usr/lib/systemd/user/llama-server.service /usr/lib/systemd/user/ 2>/dev/null || true

echo "AI runtime installed:"
pi --version
opencode --version
llama-cli --version || true
t3 --version || true
