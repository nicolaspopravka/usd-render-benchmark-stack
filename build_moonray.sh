#!/usr/bin/env bash
# Follow upstream OpenMoonRay build instructions, using ASWF dependencies.
# Keep upstream GPU defaults; install into the ASWF prefix.
set -euo pipefail

MOONRAY_TAG="${MOONRAY_TAG:?MOONRAY_TAG required, e.g. v2026.29.1}"

MOONRAY_REPO_URL="${MOONRAY_REPO_URL:-https://github.com/OpenMoonRay/openmoonray.git}"
CMAKE_INSTALL_PREFIX="${CMAKE_INSTALL_PREFIX:-${ASWF_INSTALL_PREFIX:-/usr/local}}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

# MoonRay requires OptiX 7.6 headers; ASWF installs SDK versions in separate directories.
OPTIX_ROOT="${OPTIX_ROOT:-${ASWF_INSTALL_PREFIX:-/usr/local}/NVIDIA-OptiX-SDK-7.6.0}"
CUDA_ROOT="${CUDA_ROOT:-${ASWF_INSTALL_PREFIX:-/usr/local}/cuda}"
export OPTIX_ROOT

BUILD_ROOT="${MOONRAY_BUILD_ROOT:-/opt/build-moonray}"
rm -rf "${BUILD_ROOT}"
MOONRAY_SRC="${BUILD_ROOT}/src"
MOONRAY_BUILD="${BUILD_ROOT}/build"

git clone --branch "${MOONRAY_TAG}" --recurse-submodules \
    "${MOONRAY_REPO_URL}" "${MOONRAY_SRC}"
git -C "${MOONRAY_SRC}" lfs pull

CXX_ARGS=()
if [ -n "${VFX_CXX_STANDARD:-}" ]; then
    CXX_ARGS=(-DCMAKE_CXX_STANDARD="$VFX_CXX_STANDARD"
              -DCMAKE_CXX_STANDARD_REQUIRED=ON)
fi

cmake -S "${MOONRAY_SRC}" -B "${MOONRAY_BUILD}" \
    ${CXX_ARGS[@]+"${CXX_ARGS[@]}"} \
    -DCMAKE_PREFIX_PATH="${ASWF_INSTALL_PREFIX}" \
    -DCMAKE_PROJECT_INCLUDE="${ASWF_INSTALL_PREFIX}/aswf/build-support/aswf_usd_deps.cmake" \
    -DCUDAToolkit_ROOT="${CUDA_ROOT}" \
    -DBOOST_PYTHON_COMPONENT_NAME="python${ASWF_PYTHON_MAJOR_MINOR_VERSION//./}" \
    -DBUILD_QT_APPS=NO

cmake --build "${MOONRAY_BUILD}" --parallel "${BUILD_JOBS}"

# The superproject redirects /usr/local at configure time; set the final prefix at installation.
cmake --install "${MOONRAY_BUILD}" --prefix "${CMAKE_INSTALL_PREFIX}"
