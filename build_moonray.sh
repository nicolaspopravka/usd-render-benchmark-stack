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
#   CUDA_HOST_COMPILER     optional nvcc host C++ compiler for both the CMake
#                          compiler-id test and the generated nvcc rules
#                          (CMAKE_CUDA_HOST_COMPILER + --compiler-bindir in
#                          CMAKE_CUDA_FLAGS). nvcc's supported host-gcc range
#                          tops out below gcc-toolset-14, whose <type_traits>
#                          uses intrinsics CUDA 12.9's cicc rejects
#                          (OptixGPUPrograms.ptx fails to compile), so the
#                          CY2026 recipe passes the g++ of the toolset its
#                          fixer 04 installs. Empty = let nvcc pair with the
#                          PATH default (works on the CMake-3.x-era years)
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
HOST_ARGS=()
if [ -n "${CUDA_HOST_COMPILER:-}" ]; then
    # Two mechanisms on purpose. CMAKE_CUDA_HOST_COMPILER is what CMake uses
    # for the compiler-id test; in CMake 4 it is NOT added to the generated
    # nvcc build rules, which otherwise pair with whatever gcc PATH offers
    # first (the toolset on ASWF images). CMAKE_CUDA_FLAGS reaches every
    # real nvcc invocation, so the rules are the part that must carry it.
    HOST_ARGS=(-DCMAKE_CUDA_HOST_COMPILER="${CUDA_HOST_COMPILER}" \
               "-DCMAKE_CUDA_FLAGS=--compiler-bindir=${CUDA_HOST_COMPILER}")
fi
# CMAKE_PROJECT_INCLUDE resolves the OpenUSD dependencies the ASWF deploy
# ships without configs. MoonRay, Cycles and hdEmbree all consume the same
# deployed pxr package, so they all load the same module rather than each
# growing its own workaround.
cmake -S "${MOONRAY_SRC}" -B "${MOONRAY_BUILD}" \
    -DCMAKE_PREFIX_PATH="${ASWF_INSTALL_PREFIX}" \
    -DCUDAToolkit_ROOT="${CUDA_ROOT}" \
    -DPYTHON_EXECUTABLE=python3 \
    -DBOOST_PYTHON_COMPONENT_NAME="python${ASWF_PYTHON_MAJOR_MINOR_VERSION//./}" \
    -DCMAKE_PROJECT_INCLUDE="${ASWF_INSTALL_PREFIX}/share/aswf/aswf_usd_deps.cmake" \
    "${HOST_ARGS[@]}" \
    "${POLICY_ARGS[@]}" \
    -DBUILD_QT_APPS=NO

# --- Step 3c: build -------------------------------------------------------
cmake --build "${MOONRAY_BUILD}" --parallel "${BUILD_JOBS}"

# --- Step 3d: install -----------------------------------------------------
cmake --install "${MOONRAY_BUILD}" --prefix "${CMAKE_INSTALL_PREFIX}"

rm -rf "${BUILD_ROOT}"

echo "OpenMoonRay ${MOONRAY_TAG} installed under ${CMAKE_INSTALL_PREFIX}"
