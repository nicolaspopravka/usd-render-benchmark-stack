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
# Delegate build options are left at their upstream defaults wherever the ASWF
# base can satisfy them. Upstream enables WITH_CYCLES_OSL,
# WITH_CYCLES_OPENIMAGEDENOISE, WITH_CYCLES_OPENVDB, WITH_CYCLES_NANOVDB,
# WITH_CYCLES_ALEMBIC and the WITH_CYCLES_DEVICE_* family by default, so this
# build mostly only supplies the CUDA and OptiX locators. What to keep in mind
# when reading the result:
#
#   - WITH_CYCLES_CUDA_BINARIES defaults to OFF, so the image carries OptiX
#     device code and no precompiled GPU kernels. Cycles compiles a missing
#     kernel with nvcc at render time instead, and with no precompiled kernel
#     that is the only path. That makes both CUDAToolkit_ROOT and
#     CYCLES_RUNTIME_OPTIX_ROOT_DIR load-bearing rather than merely helpful:
#     OptiXDevice::get_optix_include_dir reads OPTIX_ROOT_DIR from the
#     environment first and the compiled-in CYCLES_RUNTIME_OPTIX_ROOT_DIR
#     second, and returns an empty string - which makes
#     createOptixModuleKernel fail with "Unable to compile OptiX kernels at
#     runtime" - if neither is set. Baking the path in at build time keeps the
#     image self-sufficient instead of requiring every render environment to
#     supply it.
#   - OSL is present but incomplete, and fails late. The base's conan OSL was
#     found (1.14.11, with oslcomp, oslexec, oslquery, oslnoise and an oslc that
#     runs), but FindOSL.cmake requires only OSL_LIBRARIES, OSL_INCLUDE_DIRS and
#     OSL_COMPILER, not OSL_SHADER_DIR, so configure passes and the failure
#     appears while compiling Cycles' own OSL shaders: stdcycles.h includes
#     stdosl.h and the conan package does not deploy OSL's shader includes.
#     OpenVDB is resolved through USD's own export, because FindUSDPixar sets
#     USD_OVERRIDE_OPENVDB and the standalone find is then skipped, so
#     WITH_CYCLES_OPENVDB stays at its default.
#
# Three deviations from the defaults, each because the base cannot supply the
# dependency:
#
#   - WITH_CYCLES_NANOVDB=OFF. Observed: run 36415517826 failed at configure
#     with "Could NOT find NanoVDB (missing: NANOVDB_INCLUDE_DIR)" from
#     find_package(NanoVDB REQUIRED) in external_libs.cmake. NanoVDB is not
#     among the vfxall conan packages the images deploy.
#   - WITH_CYCLES_OPENIMAGEDENOISE=OFF. Observed on the next run: the find is
#     find_package(OpenImageDenoise REQUIRED) a few lines further on, and while
#     aswf-docker carries an openimagedenoise conan recipe, no ci-*/image.yaml
#     deploys it. Run 36418071124 passed that point.
#   - WITH_CYCLES_OSL=OFF, for the reason above. This is the one failure that
#     cannot be caught at configure time.
#
# PXR_ROOT selects FindUSDPixar, which loads OpenUSD's installed
# pxrTargets.cmake, and that export references an OpenGL::GL target the ASWF
# deploy does not define. -DCMAKE_PROJECT_INCLUDE is the shim that creates it
# first (cmake/import_openusd_dependencies.cmake); the two belong together.
#
# CMAKE_BUILD_TYPE is not a delegate option and is set explicitly. Cycles'
# top-level CMakeLists sets only CMAKE_BUILD_TYPE_INIT, which seeds the ccmake
# GUI and has no effect on a non-interactive build, so an unset build type
# leaves no -O level at all. BUILDING.md documents the build as
# "cmake --build build --config Release", but --config selects a configuration
# only for multi-configuration generators and is ignored by the
# single-configuration generators a container build uses, so the documented
# command is unoptimised on Linux unless CMAKE_BUILD_TYPE is set as well.
# Setting it at configure time is what build_scripts/build_usd.py does for USD.
#
# The compiler is provided by the build: Dockerfile.pristine wraps this script
# in the cycle year's ASWF gcc-toolset (source /opt/rh/gcc-toolset-${ASWF_DTS_VERSION}/enable).
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

# The bundle is LFS-materialized; git-lfs may be absent on some bases.
if ! command -v git-lfs >/dev/null 2>&1; then
  dnf install -y git-lfs
fi

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
    -DWITH_CYCLES_OSL=OFF \
    -DWITH_CYCLES_NANOVDB=OFF \
    -DWITH_CYCLES_OPENIMAGEDENOISE=OFF \
    -DWITH_LIBS_PRECOMPILED=OFF

  cmake --build ./build -j"$(nproc)"
  cmake --install ./build
)

rm -rf "$BUILD_ROOT"
