#!/usr/bin/env bash
set -euxo pipefail

# Canonical minimal Cycles Hydra build.
#
# Cycles is a permanent feature of this stack (ASWF images will never ship a
# ci-cycles). Built WITHOUT Blender's precompiled lib bundle: every dependency
# is resolved by CMake from the base image's /usr/local (the same OpenUSD +
# VFX-Platform libraries that serve Storm / MoonRay / Embree), so there are no
# duplicated libraries and hdCycles works under default plugin discovery with
# no extra environment.
#
# CPU/Embree only by design: no OptiX, no OpenImageDenoise, no oneAPI/SYCL, no
# CUDA/HIP, no OpenVDB/NanoVDB (the benchmark has always rendered Cycles on
# CPU).
#
# Inputs:
#   CYCLES_TAG (required)  - Cycles git tag to build, e.g. v5.0.0. Tag-only by
#                            design (MoonRay/Embree convention); the resolved
#                            HEAD is logged, no commit assert.

readonly CYCLES_URL="https://projects.blender.org/blender/cycles.git"
readonly BUILD_ROOT="/opt/build-cycles"
readonly ASWF_INSTALL_PREFIX="/usr/local"

: "${CYCLES_TAG:?CYCLES_TAG is required}"

# Cycles' CMake requires GCC >= 11.2; the prebuilt ASWF stacks ship gcc-toolset.
if [[ -e "/opt/rh/gcc-toolset-${ASWF_DTS_VERSION:-__none__}/enable" ]]; then
  # shellcheck disable=SC1090
  source "/opt/rh/gcc-toolset-${ASWF_DTS_VERSION}/enable"
else
  toolset="$(find /opt/rh -maxdepth 2 -type d -name 'gcc-toolset-*' 2>/dev/null | sort -V | tail -1)"
  if [[ -z "$toolset" ]]; then
    dnf install -y gcc-toolset-12
    toolset="$(find /opt/rh -maxdepth 2 -type d -name 'gcc-toolset-*' | sort -V | tail -1)"
  fi
  # shellcheck disable=SC1090
  source "$toolset/enable"
fi

gcc --version | head -1

# Build-time deps the base omits. Runtime stays on the base's /usr/local libs.
# libepoxy is required by the Hydra delegate (v5.0.0+ FindEpoxy) and is not
# part of the ASWF stack — a small GL-utilities wrapper, not a duplicate.
dnf install -y git glew-devel mesa-libGL-devel mesa-libEGL-devel libepoxy-devel
dnf clean all

# The delegate must be built against THIS image's OpenUSD.
test -x "$ASWF_INSTALL_PREFIX/bin/usdrecord"
PYTHONPATH="$ASWF_INSTALL_PREFIX/lib/python${PYTHONPATH:+:$PYTHONPATH}" \
  python3 -c 'from pxr import Usd; print("OpenUSD", Usd.GetVersion())'

mkdir -p "$BUILD_ROOT"
git clone --branch "$CYCLES_TAG" --depth 1 "$CYCLES_URL" "$BUILD_ROOT/cycles"
printf 'CYCLES_TAG=%s resolved HEAD=%s\n' "$CYCLES_TAG" \
  "$(git -C "$BUILD_ROOT/cycles" rev-parse HEAD)"

# OSL shader precompilation needs the OSL compiler's own shader dir (stdosl.h).
# When the base ships the OSL standard library we keep WITH_CYCLES_OSL ON and
# feed it the resolved path; otherwise OSL shading is disabled (the benchmark
# scenes render through Cycles' native nodes, which need no OSL).
stdosl="$(find "$ASWF_INSTALL_PREFIX" -path '*OSL/shaders/stdosl.h' -print -quit 2>/dev/null)"
if [[ -n "$stdosl" ]]; then
  osl_shader_dir="$(dirname "$stdosl")"
  osl_cmake_args=(-DOSL_SHADER_DIR="$osl_shader_dir")
  echo "OSL shader dir: $osl_shader_dir"
else
  osl_cmake_args=(-DWITH_CYCLES_OSL=OFF)
  echo "WARNING: stdosl.h not found under $ASWF_INSTALL_PREFIX; building with WITH_CYCLES_OSL=OFF"
fi

(
  cd "$BUILD_ROOT/cycles"

  cmake -B ./build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$ASWF_INSTALL_PREFIX" \
    -DPXR_ROOT="$ASWF_INSTALL_PREFIX" \
    -DCMAKE_PROJECT_INCLUDE=/usr/local/share/cycles/import_openusd_dependencies.cmake \
    "${osl_cmake_args[@]}" \
    -DWITH_LIBS_PRECOMPILED=OFF \
    -DWITH_CYCLES_OPENVDB=OFF \
    -DWITH_CYCLES_NANOVDB=OFF \
    -DWITH_CYCLES_OPENIMAGEDENOISE=OFF \
    -DWITH_CYCLES_ALEMBIC=OFF \
    -DWITH_CYCLES_LOGGING=OFF \
    -DWITH_CYCLES_DEVICE_ONEAPI=OFF \
    -DWITH_CYCLES_ONEAPI_BINARIES=OFF \
    -DWITH_CYCLES_DEVICE_CUDA=OFF \
    -DWITH_CYCLES_CUDA_BINARIES=OFF \
    -DWITH_CYCLES_DEVICE_HIP=OFF \
    -DWITH_CYCLES_DEVICE_HIPRT=OFF \
    -DWITH_CYCLES_HIP_BINARIES=OFF \
    -DWITH_CYCLES_DEVICE_METAL=OFF \
    -DWITH_CYCLES_DEVICE_OPTIX=OFF

  cmake --build ./build -j"$(nproc)"
  cmake --install ./build
)

# Place the delegate where a USD build with Cycles enabled would have put it:
# the compiled-in default plugin discovery root (/usr/local/plugin/usd).
# install/hydra/ = plugInfo.json + hdCycles.so + <Plugin>/resources/plugInfo.json
plugin_root="$ASWF_INSTALL_PREFIX/plugin/usd/hdCycles"
mkdir -p "$plugin_root"
cp -a "$BUILD_ROOT/cycles/install/hydra/." "$plugin_root/"
if [[ -e "$BUILD_ROOT/cycles/install/cycles" ]]; then
  install -m 755 "$BUILD_ROOT/cycles/install/cycles" "$ASWF_INSTALL_PREFIX/bin/cycles"
fi
if [[ -d "$BUILD_ROOT/cycles/install/lib" ]]; then
  cp -a "$BUILD_ROOT/cycles/install/lib/." "$ASWF_INSTALL_PREFIX/lib/"
fi
if [[ -d "$BUILD_ROOT/cycles/install/shader" ]]; then
  mkdir -p "$ASWF_INSTALL_PREFIX/share/cycles"
  cp -a "$BUILD_ROOT/cycles/install/shader/." "$ASWF_INSTALL_PREFIX/share/cycles/shader/"
fi

rm -rf "$BUILD_ROOT"