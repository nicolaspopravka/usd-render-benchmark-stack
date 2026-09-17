#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Build hdEmbree into the pristine stack image.
#
# Canonical reference: OpenUSD's in-tree hdEmbree plugin
# (pxr/imaging/plugin/hdEmbree), built externally against the base's prebuilt
# OpenUSD via the direct-linkage consumer pattern (hdCycles precedent), then
# installed into the COMPILED-IN plugin root (${ASWF_INSTALL_PREFIX}/plugin/usd)
# -- exactly where a USD build with PXR_BUILD_EMBREE_PLUGIN=ON would put it.
# The base root plugInfo.json already Includes "*/resources/", so the installed
# leaf is discovered by DEFAULT (no PXR_PLUGINPATH_NAME). One USD build per
# image: nothing here rebuilds OpenUSD.
#
# The OpenUSD source tag must match the base's prebuilt OpenUSD; it is caller
# data (per-CY), not derived. Embree always comes from the image (Nicolas).
#
# Years whose in-tree hdEmbree requires the embree3 family (23.08-25.05.01)
# are intentionally NOT dispatched: the shipped conan embree4 cannot build them
# (GH #47). That gate lives at the dispatch/process level, not here.
#
# TEMPORARY: drop this overlay when the ASWF base images ship OpenUSD with
# hdEmbree enabled.
set -euo pipefail

# --- Required input -------------------------------------------------------
OPENUSD_TAG="${OPENUSD_TAG:?OPENUSD_TAG required, e.g. v26.08}"

# --- Optional inputs ------------------------------------------------------
OPENUSD_REPO_URL="${OPENUSD_REPO_URL:-https://github.com/PixarAnimationStudios/OpenUSD.git}"
CMAKE_INSTALL_PREFIX="${CMAKE_INSTALL_PREFIX:-${ASWF_INSTALL_PREFIX:-/usr/local}}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

CONSUMER_DIR="/usr/local/aswf/cmake/hdembree-consumer"

BUILD_ROOT="$(mktemp -d)"
trap 'rm -rf "${BUILD_ROOT}"' EXIT
OPENUSD_SRC="${BUILD_ROOT}/openusd"
OPENUSD_BUILD="${BUILD_ROOT}/build"

# --- source ---------------------------------------------------------------
git clone --branch "${OPENUSD_TAG}" --depth 1 \
    "${OPENUSD_REPO_URL}" "${OPENUSD_SRC}"
git -C "${OPENUSD_SRC}" rev-parse HEAD   # recorded for evidence; not asserted

# --- configure ------------------------------------------------------------
cmake -S "${CONSUMER_DIR}" -B "${OPENUSD_BUILD}" \
    -DHDEMBREE_SOURCE_DIR="${OPENUSD_SRC}/pxr/imaging/plugin/hdEmbree" \
    -DUSD_INCLUDE_DIR="${CMAKE_INSTALL_PREFIX}/include" \
    -DUSD_LIB_DIR="${CMAKE_INSTALL_PREFIX}/lib" \
    -DEMBREE_ROOT="${CMAKE_INSTALL_PREFIX}" \
    -DCMAKE_INSTALL_PREFIX="${CMAKE_INSTALL_PREFIX}" \
    -DCMAKE_INSTALL_RPATH="${CMAKE_INSTALL_PREFIX}/lib"

# --- build ----------------------------------------------------------------
cmake --build "${OPENUSD_BUILD}" --parallel "${BUILD_JOBS}"

# --- install --------------------------------------------------------------
cmake --install "${OPENUSD_BUILD}"

echo "hdEmbree ${OPENUSD_TAG} installed under ${CMAKE_INSTALL_PREFIX}/plugin/usd"