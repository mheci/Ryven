#!/usr/bin/env bash
# Install AI runtime: Pi, OpenCode, llama.cpp (CUDA build), t3code, ryven-control, MCP server.
set -euo pipefail

echo "Installing Node.js (for Pi)..."
dnf5 install -y --skip-unavailable nodejs npm

echo "Installing Pi coding agent..."
npm install -g --ignore-scripts @earendil-works/pi-coding-agent

echo "Installing OpenCode (Go binary)..."
curl -fsSL https://opencode.ai/install | bash -s -- --dir /usr/local

echo "Installing t3code from Terra..."
dnf5 install -y --skip-unavailable t3code || dnf5 copr enable -y ponesicek/t3code-nightly-bin && dnf5 install -y --skip-unavailable t3code

echo "Building llama.cpp from source with CUDA/x86-64-v3..."
# Build dependencies
dnf5 install -y --skip-unavailable cmake gcc-c++ git cuda-nvcc cuda-cudart-devel
TMPDIR=$(mktemp -d)
git clone --depth 1 https://github.com/ggml-org/llama.cpp "${TMPDIR}"
cmake -S "${TMPDIR}" -B "${TMPDIR}/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_CUDA=ON \
    -DGGML_NATIVE=OFF \
    -DCMAKE_C_FLAGS="-march=x86-64-v3" \
    -DCMAKE_CXX_FLAGS="-march=x86-64-v3" \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_CLI=ON
cmake --build "${TMPDIR}/build" -j"$(nproc)" --target llama-cli llama-server llama-gguf-split llama-perplexity
install -m 0755 "${TMPDIR}/build/bin/llama-"* /usr/bin/
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
