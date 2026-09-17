#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Ensure a runnable ispc for MoonRay's ISPC kernels.
#
# Root cause: the ASWF-conan ispc the base deploys at /usr/local/bin/ispc is
# linked against the LLVM runtime (libclang-cpp.so.<N>) that the deploy omits,
# so every invocation fails with "error while loading shared libraries" (seen
# with libclang-cpp.so.15 on 2023.5 and the 16-era on 2024.9). MoonRay has no
# ISPC-less build path on Linux (scene_rdl2's math kernels are ISPC), so the
# deployed binary being unrunnable is fatal at compile time.
#
# The official release binary is statically linked (only glibc), so it runs
# anywhere. Version default 1.24.0: v2026.29.1's OpMap.ispc fmod kernel rejects
# ispc 1.25+ (tested), and 1.24.0 matches the ASWF CY2024 target intent.
#
# DROP THIS when the ASWF bases ship a runnable ispc.
set -euo pipefail

ISPC_VERSION="${ISPC_VERSION:-1.24.0}"

if ispc --version >/dev/null 2>&1; then
    echo "ispc OK: $(ispc --version 2>&1 | head -1)"
    exit 0
fi

echo "WARN: deployed ispc unusable ($(ispc --version 2>&1 | head -1 || true)); installing official ispc v${ISPC_VERSION}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
curl --location --fail --silent --show-error -o "${TMP}/ispc.tar.gz" \
    "https://github.com/ispc/ispc/releases/download/v${ISPC_VERSION}/ispc-v${ISPC_VERSION}-linux.tar.gz"
tar -xzf "${TMP}/ispc.tar.gz" -C "${TMP}"
install -m 0755 "${TMP}/ispc-v${ISPC_VERSION}-linux/bin/ispc" /usr/local/bin/ispc
ispc --version
echo "installed official ispc v${ISPC_VERSION} at /usr/local/bin/ispc"