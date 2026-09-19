#!/usr/bin/env bash
set -euxo pipefail

# Canonical minimal Cycles Hydra build.
#
# Cycles is a permanent feature of this stack (ASWF images will never ship a
# ci-cycles) and is NOT an ASWF project: it installs self-contained under
# /opt/cycles, activated through PXR_PLUGINPATH_NAME in the runnable.
#
# Built WITHOUT Blender's precompiled lib bundle: every dependency is resolved
# by CMake from the stack's own libraries. The single dependency the ASWF base
# does not provide is libepoxy (Cycles' FindEpoxy) — taken from Cycles' own
# pinned lib/linux_x64 submodule and installed into /usr/local like a system
# lib (it is a static archive in the bundle, so nothing extra is needed at
# runtime). No duplicated libraries.
#
# CPU/Embree only by design: no OptiX, no OpenImageDenoise, no oneAPI/SYCL, no
# CUDA/HIP, no OpenVDB/NanoVDB, and no OSL shading (WITH_CYCLES_OSL=OFF — the
# conan OSL deploy ships no stdosl.h, and the benchmark scenes render through
# Cycles' native nodes).
#
# The compiler is provided by the build: Dockerfile.pristine wraps this script
# in the cycle year's ASWF gcc-toolset (source /opt/rh/gcc-toolset-${ASWF_DTS_VERSION}/enable).
#
# Inputs:
#   CYCLES_TAG (required)  - Cycles git tag to build, e.g. v5.0.0. Tag-only by
#                            design (MoonRay/Embree convention); the resolved
#                            HEAD is logged, no commit assert.

readonly CYCLES_URL="https://projects.blender.org/blender/cycles.git"
readonly CYCLES_LIB_URL="https://projects.blender.org/blender/lib-linux_x64.git"
readonly BUILD_ROOT="/opt/build-cycles"
readonly ASWF_INSTALL_PREFIX="/usr/local"
readonly CYCLES_INSTALL_PREFIX="/opt/cycles"

: "${CYCLES_TAG:?CYCLES_TAG is required}"

# The bundle is LFS-materialized; git-lfs may be absent on some bases.
if ! command -v git-lfs >/dev/null 2>&1; then
  dnf install -y git-lfs
fi

# The delegate must be built against THIS image's OpenUSD.
test -x "$ASWF_INSTALL_PREFIX/bin/usdrecord"
PYTHONPATH="$ASWF_INSTALL_PREFIX/lib/python${PYTHONPATH:+:$PYTHONPATH}" \
  python3 -c 'from pxr import Usd; print("OpenUSD", Usd.GetVersion())'

mkdir -p "$BUILD_ROOT"
git clone --branch "$CYCLES_TAG" --depth 1 "$CYCLES_URL" "$BUILD_ROOT/cycles"
printf 'CYCLES_TAG=%s resolved HEAD=%s\n' "$CYCLES_TAG" \
  "$(git -C "$BUILD_ROOT/cycles" rev-parse HEAD)"

# OSL shader precompilation is skipped (WITH_CYCLES_OSL=OFF), so the delegate
# build does not depend on the OSL compiler's stdosl.h.

# --- libepoxy from Cycles' pinned lib/linux_x64 submodule -------------------
# The bundle commit is the gitlink the tag's `make update` would use.
bundle_commit="$(git -C "$BUILD_ROOT/cycles" ls-tree HEAD lib/linux_x64 | awk '{print $3}')"
test -n "$bundle_commit"
git clone --filter=blob:none "$CYCLES_LIB_URL" "$BUILD_ROOT/lib-linux_x64"
git -C "$BUILD_ROOT/lib-linux_x64" checkout --detach "$bundle_commit"
git -C "$BUILD_ROOT/lib-linux_x64" lfs install --skip-repo
git -C "$BUILD_ROOT/lib-linux_x64" lfs pull -I 'epoxy/**'

# The bundle's epoxy is a static archive + headers; install into /usr/local
# (system-wide like GL, nowhere near the /opt/cycles tree).
bundle_epoxy="$BUILD_ROOT/lib-linux_x64/epoxy"
test -d "$bundle_epoxy/include" && test -d "$bundle_epoxy/lib"
cp -a "$bundle_epoxy/include/." "$ASWF_INSTALL_PREFIX/include/"
cp -a "$bundle_epoxy/lib/." "$ASWF_INSTALL_PREFIX/lib/"
find "$ASWF_INSTALL_PREFIX/include" -path '*epoxy*' -name 'gl.h' -print -quit >/dev/null
find "$ASWF_INSTALL_PREFIX/lib" -name 'libepoxy*' -print -quit >/dev/null
echo "libepoxy installed under $ASWF_INSTALL_PREFIX (from $CYCLES_TAG's bundle gitlink $bundle_commit)"

(
  cd "$BUILD_ROOT/cycles"

  cmake -B ./build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$CYCLES_INSTALL_PREFIX" \
    -DCMAKE_PREFIX_PATH="$ASWF_INSTALL_PREFIX" \
    -DPXR_ROOT="$ASWF_INSTALL_PREFIX" \
    -DCMAKE_PROJECT_INCLUDE=/usr/local/share/cycles/import_openusd_dependencies.cmake \
    -DWITH_CYCLES_OSL=OFF \
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

rm -rf "$BUILD_ROOT"