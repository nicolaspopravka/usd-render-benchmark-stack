#!/usr/bin/env bash
# Follow upstream Cycles build instructions, using ASWF dependencies.
# Install into /opt/cycles; profiles select source and feature overrides.
set -euxo pipefail

readonly CYCLES_REPO_URL="${CYCLES_REPO_URL:-https://projects.blender.org/blender/cycles.git}"
readonly BUILD_ROOT="/opt/build-cycles"
readonly ASWF_INSTALL_PREFIX="/usr/local"
readonly CYCLES_INSTALL_PREFIX="/opt/cycles"
readonly WITH_CYCLES_OSL="${WITH_CYCLES_OSL:-ON}"
readonly WITH_CYCLES_OPENVDB="${WITH_CYCLES_OPENVDB:-ON}"

# ASWF keeps SDK headers outside normal discovery paths; the runtime also needs this location.
readonly OPTIX_ROOT_DIR="${OPTIX_ROOT_DIR:-${ASWF_INSTALL_PREFIX}/NVIDIA-OptiX-SDK-8.0.0}"
readonly CYCLES_RUNTIME_OPTIX_ROOT_DIR="${OPTIX_ROOT_DIR}"

: "${CYCLES_TAG:?CYCLES_TAG is required}"

mkdir -p "$BUILD_ROOT"
git clone --branch "$CYCLES_TAG" --depth 1 "$CYCLES_REPO_URL" "$BUILD_ROOT/cycles"
git -C "$BUILD_ROOT/cycles" rev-parse HEAD

CXX_ARGS=()
if [ -n "${VFX_CXX_STANDARD:-}" ]; then
    CXX_ARGS=(-DCMAKE_CXX_STANDARD="$VFX_CXX_STANDARD"
              -DCMAKE_CXX_STANDARD_REQUIRED=ON)
fi

(
  cd "$BUILD_ROOT/cycles"

  # ASWF lacks NanoVDB/OIDN; use its dependencies instead of Blender precompiled libraries.
  cmake -B ./build \
    ${CXX_ARGS[@]+"${CXX_ARGS[@]}"} \
    -DCMAKE_INSTALL_PREFIX="$CYCLES_INSTALL_PREFIX" \
    -DPXR_ROOT="$ASWF_INSTALL_PREFIX" \
    -DPython3_ROOT_DIR="$ASWF_INSTALL_PREFIX" \
    -DWITH_CYCLES_OSL="$WITH_CYCLES_OSL" \
    -DWITH_CYCLES_OPENVDB="$WITH_CYCLES_OPENVDB" \
    -DCMAKE_PROJECT_INCLUDE="${ASWF_INSTALL_PREFIX}/aswf/build-support/aswf_usd_deps.cmake" \
    -DOPTIX_ROOT_DIR="$OPTIX_ROOT_DIR" \
    -DCYCLES_RUNTIME_OPTIX_ROOT_DIR="$CYCLES_RUNTIME_OPTIX_ROOT_DIR" \
    -DWITH_CYCLES_NANOVDB=OFF \
    -DWITH_CYCLES_OPENIMAGEDENOISE=OFF \
    -DWITH_LIBS_PRECOMPILED=OFF

  cmake --build ./build -j"$(nproc)"
  cmake --install ./build
)
