#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Build OpenMoonRay into the pristine stack image.
# Canonical reference: the official Rocky 9 container build
#   https://docs.openmoonray.org/getting-started/installation/building-moonray/rocky9_container_build
# The aswf/ci-moonray base already satisfies that guide's Steps 1-2; this script
# is its Step 3.
#
# MOONRAY_USE_OPTIX is left at its upstream default, YES on Linux, so the build
# produces XPU support and the OptiX GPU programs. That default is
# GPU-mandatory rather than optional: find_package(CUDAToolkit REQUIRED) and
# find_package(OptiX REQUIRED) both hard-fail, so a base without them stops at
# configure rather than falling back to CPU.
#
# Environment-bound deltas:
#   BUILD_QT_APPS=NO       the default is YES when REZ_QT_MAJOR_VERSION is unset,
#                          which it is in the base, and there is no Qt here
#   CUDAToolkit_ROOT       CUDA is under ${prefix}/cuda, not on PATH; the
#                          superproject only fixes PATH when this is already set
#   OPTIX_ROOT             an env var, not a CMake one: upstream's FindOptiX.cmake
#                          is a HINTS-only find_path over $OPTIX_ROOT/include and
#                          /usr/local/include, and the SDKs sit as sibling
#                          NVIDIA-OptiX-SDK-<version> directories. It has no version
#                          check, and 7.6.0 is required - mcrt_denoise uses
#                          OptixDenoiserParams::denoiseAlpha, removed in OptiX 8
#   cmake --install --prefix  OpenMoonRay remaps CMAKE_INSTALL_PREFIX=/usr/local
#                          to <source>/release at configure time
#
# No workarounds live here; an ASWF-defect fix belongs in a separate RUN step in
# Dockerfile.pristine, driven by that evidence.
set -euo pipefail

# --- Required input -------------------------------------------------------
MOONRAY_TAG="${MOONRAY_TAG:?MOONRAY_TAG required, e.g. v2026.29.1}"

# --- Optional inputs ------------------------------------------------------
MOONRAY_REPO_URL="${MOONRAY_REPO_URL:-https://github.com/OpenMoonRay/openmoonray.git}"
CMAKE_INSTALL_PREFIX="${CMAKE_INSTALL_PREFIX:-${ASWF_INSTALL_PREFIX:-/usr/local}}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

# OptiX SDK root, read from the environment by upstream's FindOptiX.cmake.
# aswf-docker's install_optix.sh installs every available header version as
# ${ASWF_INSTALL_PREFIX}/NVIDIA-OptiX-SDK-<version>; 7.6.0 is the version
# OpenMoonRay documents (see the header note above).
OPTIX_ROOT="${OPTIX_ROOT:-${ASWF_INSTALL_PREFIX:-/usr/local}/NVIDIA-OptiX-SDK-7.6.0}"
CUDA_ROOT="${CUDA_ROOT:-${ASWF_INSTALL_PREFIX:-/usr/local}/cuda}"
export OPTIX_ROOT

# A fixed build root, not mktemp -d. The path is compiled into the artifacts -
# compiler diagnostics and CMake's own bookkeeping both carry it - so a random
# directory yields a different image on every build from the same commit and the
# same base. That makes the .2 digest unstable, and any .2 rebuild then
# invalidates the .3 built on top of it. Cycles already builds this way, at
# /opt/build-cycles. Overridable for a caller that needs an isolated root.
BUILD_ROOT="${MOONRAY_BUILD_ROOT:-/opt/build-moonray}"
rm -rf "${BUILD_ROOT}"
MOONRAY_SRC="${BUILD_ROOT}/src"
MOONRAY_BUILD="${BUILD_ROOT}/build"

# --- Step 3a: source ------------------------------------------------------
# The superproject references 19 submodules; some track files via LFS.
git clone --branch "${MOONRAY_TAG}" --recurse-submodules \
    "${MOONRAY_REPO_URL}" "${MOONRAY_SRC}"
git -C "${MOONRAY_SRC}" rev-parse HEAD   # recorded for evidence; not asserted
git -C "${MOONRAY_SRC}" lfs pull

# --- Step 3b: configure ---------------------------------------------------
# CMake 4 removed compatibility with cmake_minimum_required() < 3.5, which
# the pinned cmake_modules FindTBB.cmake (and other old modules in the tree)
# still declare, and it dropped the FindTBB module behind CMP0167. The ASWF
# CY2026+ images ship CMake 4 while older years ship 3.x, so the flags are
# added only when cmake --version reports 4/5 and the 3.x configure stays
# byte-identical.
POLICY_ARGS=()
if cmake --version | grep -qE '^cmake version (4|5)\.'; then
    POLICY_ARGS=(-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_POLICY_DEFAULT_CMP0167=NEW)
fi
cmake -S "${MOONRAY_SRC}" -B "${MOONRAY_BUILD}" \
    -DCMAKE_PREFIX_PATH="${ASWF_INSTALL_PREFIX}" \
    -DCUDAToolkit_ROOT="${CUDA_ROOT}" \
    -DPYTHON_EXECUTABLE=python3 \
    -DBOOST_PYTHON_COMPONENT_NAME="python${ASWF_PYTHON_MAJOR_MINOR_VERSION//./}" \
    "${POLICY_ARGS[@]}" \
    -DBUILD_QT_APPS=NO

# --- Step 3c: build -------------------------------------------------------
cmake --build "${MOONRAY_BUILD}" --parallel "${BUILD_JOBS}"

# --- Step 3d: install -----------------------------------------------------
cmake --install "${MOONRAY_BUILD}" --prefix "${CMAKE_INSTALL_PREFIX}"

rm -rf "${BUILD_ROOT}"

echo "OpenMoonRay ${MOONRAY_TAG} installed under ${CMAKE_INSTALL_PREFIX}"
