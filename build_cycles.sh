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
# WITH_CYCLES_OSL stays at its upstream default (ON), which needs fixers/05 to
# install the OSL shader includes the conan package omits.
#
# Three additions, all from measured build failures rather than preference:
#
#   Python3_ROOT_DIR   Cycles asks find_package(Python3 EXACT 3.10.20), and the
#                      base's own USD pxrConfig.cmake asks for the same patch
#                      version, but CMake does not resolve /usr/local on its
#                      own: it finds libpython3.10.so, derives the version from
#                      the filename, then fails to resolve the headers. Passing
#                      the install prefix is a documented CMake variable and
#                      changes no source. Benchmark GH #53, fixed in
#                      nico/fix/cycles-python-locator.
#
#   WITH_CYCLES_OSL    Off for CY2023 and CY2024. aswf-docker builds OSL against
#                      a newer LLVM than the same image deploys: CY2023 oslc
#                      needs libLLVM-15.so and the image ships 14, CY2024 needs
#                      libLTO.so.17 and ships 16, CY2025 matches at 18 and builds
#                      OSL on. The deployed OSL binary also matches neither the
#                      declared ASWF_OSL_CLANG_VERSION pin nor the LLVM beside it,
#                      which is why the mismatch is in the artifact. Benchmark
#                      GH #54. Both years' published .3 images are already
#                      OSL-off, so this preserves the existing posture.
#
#   WITH_CYCLES_OPENVDB Off for CY2023 and CY2024. aswf-docker's OpenVDB recipe
#                      sets use_delayed_loading=False against OpenVDB's own
#                      default of ON, and omits the option from package_id, so
#                      every image ships an OpenVDB whose io::File lacks the
#                      delayed-loading setter Cycles' Hydra volume loader calls
#                      unguarded before v4.4.0. Compiling it away is not a fix:
#                      OPENVDB_USE_DELAYED_LOADING is a library-build setting, so
#                      defining it at the consumer compiles and then fails to
#                      link. Benchmark GH #56. The cost is Moana Island's VDB
#                      volume data on those two years, which is a documented
#                      per-year deviation and not a delegate defect.
#
# Both delegate values default to ON, so a year that needs neither says nothing
# and CY2025 is unaffected.
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
# ON is the upstream default and what CY2025 builds. Only a year whose ASWF base
# cannot support the delegate passes OFF; see the header.
readonly WITH_CYCLES_OSL="${WITH_CYCLES_OSL:-ON}"
readonly WITH_CYCLES_OPENVDB="${WITH_CYCLES_OPENVDB:-ON}"

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

# --- libepoxy -------------------------------------------------------------
# Cycles' FindEpoxy is REQUIRED whenever the Hydra delegate is built, and ASWF
# ships GLEW via Conan and no epoxy at all. It comes from one of two places,
# auto-detected from the tag:
#   * tags with a lib/linux_x64 gitlink (v4.1.1+) - the pinned bundle epoxy,
#     installed into /usr/local (a static archive, so nothing extra at runtime);
#   * tags without one (v4.0.x and older) - no bundle exists, so the distro
#     package is installed and left where the distro puts it.
# Both satisfy the same find and neither duplicates a library. A per-year
# difference worth recording: the bundle is static, the distro package is
# shared, so a distro-epoxy year's hdCycles.so carries a runtime
# DT_NEEDED libepoxy.so.0 (the rocky8 soname).
#
# The gitlink is resolved BEFORE cloning the bundle, since older tags name it
# lib/linux_x86_64 and some have no submodule at all.
bundle_commit="$(git -C "$BUILD_ROOT/cycles" ls-tree HEAD lib/linux_x64 2>/dev/null | awk '{print $3}')"
if [[ -z "$bundle_commit" ]]; then
  bundle_commit="$(git -C "$BUILD_ROOT/cycles" ls-tree HEAD lib/linux_x86_64 2>/dev/null | awk '{print $3}')"
fi

if [[ -n "$bundle_commit" ]]; then
  # The bundle is LFS-materialized; git-lfs may be absent on some bases.
  if ! command -v git-lfs >/dev/null 2>&1; then
    dnf install -y git-lfs
  fi
  git clone --filter=blob:none "$CYCLES_LIB_URL" "$BUILD_ROOT/lib-linux_x64"
  git -C "$BUILD_ROOT/lib-linux_x64" checkout --detach "$bundle_commit"
  git -C "$BUILD_ROOT/lib-linux_x64" lfs install --skip-repo
  git -C "$BUILD_ROOT/lib-linux_x64" lfs pull -I 'epoxy/**'

  # cp of a missing source fails the build, so no prior layout check is needed.
  bundle_epoxy="$BUILD_ROOT/lib-linux_x64/epoxy"
  cp -a "$bundle_epoxy/include/." "$ASWF_INSTALL_PREFIX/include/"
  cp -a "$bundle_epoxy/lib/." "$ASWF_INSTALL_PREFIX/lib/"
  echo "Using pinned bundle libepoxy from lib-linux_x64@$bundle_commit"
else
  # v4.0.x's external_libs.cmake only sets CMAKE_IGNORE_PATH inside its bundle
  # branch, so with no bundle it leaves the system paths searchable and
  # FindEpoxy resolves epoxy/gl.h and the library from the distro locations as
  # installed. Leaving the file where the distro put it also keeps one copy,
  # owned by rpm, already in the loader cache.
  dnf install -y libepoxy-devel
  rpm -q libepoxy-devel libepoxy
  echo "Using distro libepoxy (no lib/linux* submodule in $CYCLES_TAG)"
fi

(
  cd "$BUILD_ROOT/cycles"

  cmake -B ./build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$CYCLES_INSTALL_PREFIX" \
    -DPXR_ROOT="$ASWF_INSTALL_PREFIX" \
    -DPython3_ROOT_DIR="$ASWF_INSTALL_PREFIX" \
    -DWITH_CYCLES_OSL="$WITH_CYCLES_OSL" \
    -DWITH_CYCLES_OPENVDB="$WITH_CYCLES_OPENVDB" \
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
