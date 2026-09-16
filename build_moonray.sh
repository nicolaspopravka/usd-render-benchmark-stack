#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Build OpenMoonRay into the pristine stack image.
#
# Canonical reference: the official Rocky 9 container build
#   https://docs.openmoonray.org/getting-started/installation/building-moonray/rocky9_container_build
#
# Step mapping (the aswf/ci-moonray base already satisfies Steps 1-2):
#   Step 1  install_packages.sh --nocuda   -> satisfied by the base image
#   Step 2  building/Rocky9 dependencies   -> deployed under ${ASWF_INSTALL_PREFIX}
#   Step 3  this script: source -> configure -> build -> install
#
# Documented deltas (environment-bound, not workarounds):
#   - -DCMAKE_PREFIX_PATH="${ASWF_INSTALL_PREFIX}": ASWF deps live there, not
#     /usr (matches the aswf-docker build-script convention, e.g. build_alembic.sh).
#   - -DBUILD_QT_APPS=NO: the MoonRay cmake defaults it to YES when
#     REZ_QT_MAJOR_VERSION is unset (it is, in the base); we do not build the GUI.
#   - The cmake --install --prefix is required because OpenMoonRay's CMakeLists
#     remaps CMAKE_INSTALL_PREFIX=/usr/local to <source>/release at configure time.
#
# No workarounds live here. When this build fails on an ASWF-defect, the fix is
# added as a separate RUN step in Dockerfile.pristine, driven by that evidence.
set -euo pipefail

# --- Required input -------------------------------------------------------
MOONRAY_TAG="${MOONRAY_TAG:?MOONRAY_TAG required, e.g. v2026.29.1}"

# --- Optional inputs ------------------------------------------------------
MOONRAY_REPO_URL="${MOONRAY_REPO_URL:-https://github.com/OpenMoonRay/openmoonray.git}"
CMAKE_INSTALL_PREFIX="${CMAKE_INSTALL_PREFIX:-${ASWF_INSTALL_PREFIX:-/usr/local}}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

BUILD_ROOT="$(mktemp -d)"
trap 'rm -rf "${BUILD_ROOT}"' EXIT
MOONRAY_SRC="${BUILD_ROOT}/src"
MOONRAY_BUILD="${BUILD_ROOT}/build"

# --- Step 3a: source ------------------------------------------------------
# The superproject references 19 submodules; some track files via LFS.
git clone --branch "${MOONRAY_TAG}" --recurse-submodules \
    "${MOONRAY_REPO_URL}" "${MOONRAY_SRC}"
git -C "${MOONRAY_SRC}" rev-parse HEAD   # recorded for evidence; not asserted
git -C "${MOONRAY_SRC}" lfs pull

# --- Step 3b: configure ---------------------------------------------------
cmake -S "${MOONRAY_SRC}" -B "${MOONRAY_BUILD}" \
    -DCMAKE_PREFIX_PATH="${ASWF_INSTALL_PREFIX}" \
    -DPYTHON_EXECUTABLE=python3 \
    -DBOOST_PYTHON_COMPONENT_NAME="python${ASWF_PYTHON_MAJOR_MINOR_VERSION//./}" \
    -DABI_VERSION=0 \
    -DBUILD_QT_APPS=NO \
    -DMOONRAY_USE_OPTIX=NO

# --- Step 3c: build -------------------------------------------------------
cmake --build "${MOONRAY_BUILD}" --parallel "${BUILD_JOBS}"

# --- Step 3d: install -----------------------------------------------------
cmake --install "${MOONRAY_BUILD}" --prefix "${CMAKE_INSTALL_PREFIX}"

echo "OpenMoonRay ${MOONRAY_TAG} installed under ${CMAKE_INSTALL_PREFIX}"
