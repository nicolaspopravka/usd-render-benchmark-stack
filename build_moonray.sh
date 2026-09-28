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
# Delegate build options are left at their upstream defaults. MOONRAY_USE_OPTIX
# defaults to YES on Linux, so this build produces XPU support and the OptiX GPU
# programs rather than excluding them. Note what that default means: OpenMoonRay
# requires both CUDA and OptiX, find_package(CUDAToolkit REQUIRED) and
# find_package(OptiX REQUIRED), so a build without them fails at configure time
# instead of falling back to CPU.
#
# Documented deltas (environment-bound, not workarounds):
#   - -DCMAKE_PREFIX_PATH="${ASWF_INSTALL_PREFIX}": ASWF deps live there, not
#     /usr (matches the aswf-docker build-script convention, e.g. build_alembic.sh).
#   - -DBUILD_QT_APPS=NO: the MoonRay cmake defaults it to YES when
#     REZ_QT_MAJOR_VERSION is unset (it is, in the base); we do not build the GUI.
#   - -DCUDAToolkit_ROOT: the ASWF images install CUDA under
#     ${ASWF_INSTALL_PREFIX}/cuda, which is not on PATH. The superproject only
#     adds the toolkit to PATH for its check_language(CUDA) when this value is
#     already set, and find_package(CUDAToolkit REQUIRED) follows.
#   - OPTIX_ROOT: upstream's FindOptiX.cmake is a HINTS-only find_path over
#     $ENV{OPTIX_ROOT}/include and /usr/local/include. aswf-docker's
#     install_optix.sh installs twelve OptiX header sets as sibling directories
#     named NVIDIA-OptiX-SDK-<version>, never merged into ${ASWF_INSTALL_PREFIX},
#     so the variable is required to find any of them. It is an environment
#     variable, not a CMake one. 7.6.0 is the version OpenMoonRay documents and
#     requires: mcrt_denoise uses OptixDenoiserParams::denoiseAlpha, which OptiX
#     8 removed, and the finder does no version check, so pointing it at 8.0.0
#     would configure successfully and then fail to compile.
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

# OptiX SDK root, read from the environment by upstream's FindOptiX.cmake.
# aswf-docker's install_optix.sh installs every available header version as
# ${ASWF_INSTALL_PREFIX}/NVIDIA-OptiX-SDK-<version>; 7.6.0 is the version
# OpenMoonRay documents (see the header note above).
OPTIX_ROOT="${OPTIX_ROOT:-${ASWF_INSTALL_PREFIX:-/usr/local}/NVIDIA-OptiX-SDK-7.6.0}"
CUDA_ROOT="${CUDA_ROOT:-${ASWF_INSTALL_PREFIX:-/usr/local}/cuda}"
export OPTIX_ROOT

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
    -DCUDAToolkit_ROOT="${CUDA_ROOT}" \
    -DPYTHON_EXECUTABLE=python3 \
    -DBOOST_PYTHON_COMPONENT_NAME="python${ASWF_PYTHON_MAJOR_MINOR_VERSION//./}" \
    -DBUILD_QT_APPS=NO

# --- Step 3c: build -------------------------------------------------------
cmake --build "${MOONRAY_BUILD}" --parallel "${BUILD_JOBS}"

# --- Step 3d: install -----------------------------------------------------
cmake --install "${MOONRAY_BUILD}" --prefix "${CMAKE_INSTALL_PREFIX}"

echo "OpenMoonRay ${MOONRAY_TAG} installed under ${CMAKE_INSTALL_PREFIX}"
