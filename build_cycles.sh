#!/usr/bin/env bash
set -euxo pipefail

# Canonical minimal Cycles Hydra build.
#
# Cycles is not an ASWF project and no ASWF image ships one: it installs
# self-contained under /opt/cycles, activated via PXR_PLUGINPATH_NAME in the
# runnable. Dockerfile.pristine wraps this script in the cycle year's ASWF
# gcc-toolset.
#
# Delegate options are upstream defaults except the three below, each because the
# ASWF base cannot supply the dependency:
#
#   WITH_CYCLES_NANOVDB=OFF           no nanovdb in the vfxall conan packages
#   WITH_CYCLES_OPENIMAGEDENOISE=OFF  aswf-docker has the recipe, no image deploys it
#   WITH_LIBS_PRECOMPILED=OFF         the pinned bundle carries OIIO 3.0.9, Imath 3.0
#                                     and OpenEXR -3_3 beside the conan stack's 3.1.x
#
# WITH_CYCLES_OSL also stays at its default, which needs fixers/05 to install the
# OSL shader includes the conan package omits.
#
# Locators, because the ASWF images keep these outside CMake's search paths:
# the CUDA toolkit under ${prefix}/cuda, and the OptiX SDKs as sibling
# NVIDIA-OptiX-SDK-<version> directories rather than merged into ${prefix}.
# CYCLES_RUNTIME_OPTIX_ROOT_DIR is baked in because WITH_CYCLES_CUDA_BINARIES is
# off by default, so there is no prebuilt kernel and the render-time nvcc path
# is the only one; without it OptiX fails at render, not at build.
#
# PXR_ROOT and -DCMAKE_PROJECT_INCLUDE go together: the former makes CMake load
# OpenUSD's installed pxrTargets.cmake, which references an OpenGL::GL target the
# ASWF deploy does not define, and the latter is the shim that defines it first.
#
# CMAKE_BUILD_TYPE is pinned because every published timing depends on it. It is
# already Release by default here - Cycles seeds CMAKE_BUILD_TYPE_INIT before
# project() - so this is a pin, not a workaround. BUILDING.md's
# "cmake --build build --config Release" is a no-op for the single-config
# generators a container build uses.
#
# Inputs:
#   CYCLES_TAG (required)  - Cycles git tag to build, e.g. v5.0.0. Tag-only by
#                            design (MoonRay/Embree convention); no commit assert.

readonly CYCLES_URL="https://projects.blender.org/blender/cycles.git"
readonly CYCLES_LIB_URL="https://projects.blender.org/blender/lib-linux_x64.git"
readonly BUILD_ROOT="/opt/build-cycles"
readonly ASWF_INSTALL_PREFIX="/usr/local"
readonly CYCLES_INSTALL_PREFIX="/opt/cycles"

# CUDA and OptiX live outside CMake's default search paths in the ASWF images,
# so the upstream device defaults need a locator. aswf-docker's install_optix.sh
# installs every available OptiX header set as a sibling directory named
# NVIDIA-OptiX-SDK-<version>, never merged into ${ASWF_INSTALL_PREFIX}, and
# FindOptiX.cmake only searches that variable plus the standard prefixes, so
# without it OptiX is not found and the device silently stays off. Cycles
# requires OptiX 8.0.0 or newer (find_package(OptiX 8.0.0)), and its finder
# version-checks the optix.h it locates, so this cannot select a wrong SDK.
readonly OPTIX_ROOT_DIR="${OPTIX_ROOT_DIR:-${ASWF_INSTALL_PREFIX}/NVIDIA-OptiX-SDK-8.0.0}"
# Baked in because WITH_CYCLES_CUDA_BINARIES is off by default, so there is no
# precompiled OptiX kernel in the image and the render-time nvcc path is the
# only one. See the note in the header.
readonly CYCLES_RUNTIME_OPTIX_ROOT_DIR="${OPTIX_ROOT_DIR}"
readonly CUDAToolkit_ROOT="${CUDAToolkit_ROOT:-${ASWF_INSTALL_PREFIX}/cuda}"

: "${CYCLES_TAG:?CYCLES_TAG is required}"

mkdir -p "$BUILD_ROOT"
git clone --branch "$CYCLES_TAG" --depth 1 "$CYCLES_URL" "$BUILD_ROOT/cycles"

# --- libepoxy from Cycles' pinned lib/linux_x64 submodule -------------------
# The bundle commit is the gitlink the tag's `make update` would use. Resolve it
# BEFORE cloning the bundle (older tags name it lib/linux_x86_64; some have no
# submodule at all). No submodule -> no way to source the pinned libepoxy here.
bundle_commit="$(git -C "$BUILD_ROOT/cycles" ls-tree HEAD lib/linux_x64 2>/dev/null | awk '{print $3}')"
if [[ -z "$bundle_commit" ]]; then
  bundle_commit="$(git -C "$BUILD_ROOT/cycles" ls-tree HEAD lib/linux_x86_64 2>/dev/null | awk '{print $3}')"
fi
if [[ -z "$bundle_commit" ]]; then
  echo "ERROR: $CYCLES_TAG has no lib/linux* submodule — cannot source the pinned libepoxy" >&2
  exit 1
fi
git clone --filter=blob:none "$CYCLES_LIB_URL" "$BUILD_ROOT/lib-linux_x64"
git -C "$BUILD_ROOT/lib-linux_x64" checkout --detach "$bundle_commit"
git -C "$BUILD_ROOT/lib-linux_x64" lfs install --skip-repo
git -C "$BUILD_ROOT/lib-linux_x64" lfs pull -I 'epoxy/**'

# The bundle's epoxy is a static archive + headers; install into /usr/local
# (system-wide like GL, nowhere near the /opt/cycles tree). cp of a missing
# source fails the build, so no prior layout check is needed.
bundle_epoxy="$BUILD_ROOT/lib-linux_x64/epoxy"
cp -a "$bundle_epoxy/include/." "$ASWF_INSTALL_PREFIX/include/"
cp -a "$bundle_epoxy/lib/." "$ASWF_INSTALL_PREFIX/lib/"

(
  cd "$BUILD_ROOT/cycles"

  cmake -B ./build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$CYCLES_INSTALL_PREFIX" \
    -DPXR_ROOT="$ASWF_INSTALL_PREFIX" \
    -DCMAKE_PROJECT_INCLUDE="${ASWF_INSTALL_PREFIX}/share/cycles/import_openusd_dependencies.cmake" \
    -DOPTIX_ROOT_DIR="$OPTIX_ROOT_DIR" \
    -DCYCLES_RUNTIME_OPTIX_ROOT_DIR="$CYCLES_RUNTIME_OPTIX_ROOT_DIR" \
    -DCUDAToolkit_ROOT="$CUDAToolkit_ROOT" \
    -DWITH_CYCLES_NANOVDB=OFF \
    -DWITH_CYCLES_OPENIMAGEDENOISE=OFF \
    -DWITH_LIBS_PRECOMPILED=OFF

  cmake --build ./build -j"$(nproc)"
  cmake --install ./build
)

rm -rf "$BUILD_ROOT"
