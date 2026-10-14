#!/usr/bin/env bash
# Keep a working ISPC; otherwise replace it with the official static binary.
# The default version preserves compatibility with older MoonRay kernels.
set -euo pipefail

ISPC_VERSION="${ISPC_VERSION:-1.24.0}"

if ispc --version >/dev/null 2>&1; then
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
curl --location --fail --silent --show-error -o "${TMP}/ispc.tar.gz" \
    "https://github.com/ispc/ispc/releases/download/v${ISPC_VERSION}/ispc-v${ISPC_VERSION}-linux.tar.gz"
tar -xzf "${TMP}/ispc.tar.gz" -C "${TMP}"
install -m 0755 "${TMP}/ispc-v${ISPC_VERSION}-linux/bin/ispc" /usr/local/bin/ispc
ispc --version
