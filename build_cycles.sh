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
# does not provide is libepoxy (Cycles' FindEpoxy, REQUIRED whenever the Hydra
# delegate is built). ASWF ships GLEW via Conan and has no epoxy at all, so
# epoxy comes from one of two places, auto-detected from the tag:
#   * tags with a lib/linux_x64 gitlink (v4.1.1+) — the pinned bundle epoxy,
#     installed into /usr/local (a static archive; the throwaway LFS clone is
#     then removed, so this moves rather than duplicates);
#   * tags without one (v4.0.x and older) — no bundle exists, so the distro
#     package is installed and left where the distro puts it.
# Both paths satisfy the same find, and neither duplicates a library.
# Per-year difference worth recording: the bundle is static, the distro package
# is shared, so a distro-epoxy year's hdCycles.so carries a runtime
# DT_NEEDED libepoxy.so.0 (the soname on rocky8; .so.2 on newer distros).
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
#                            design (MoonRay/Embree convention); no commit assert.

readonly CYCLES_URL="https://projects.blender.org/blender/cycles.git"
readonly CYCLES_LIB_URL="https://projects.blender.org/blender/lib-linux_x64.git"
readonly BUILD_ROOT="/opt/build-cycles"
readonly ASWF_INSTALL_PREFIX="/usr/local"
readonly CYCLES_INSTALL_PREFIX="/opt/cycles"

: "${CYCLES_TAG:?CYCLES_TAG is required}"

mkdir -p "$BUILD_ROOT"
git clone --branch "$CYCLES_TAG" --depth 1 "$CYCLES_URL" "$BUILD_ROOT/cycles"

# --- libepoxy -------------------------------------------------------------
# The bundle commit is the gitlink the tag's `make update` would use. Resolve it
# BEFORE cloning the bundle (older tags name it lib/linux_x86_64; some have no
# submodule at all).
bundle_commit="$(git -C "$BUILD_ROOT/cycles" ls-tree HEAD lib/linux_x64 2>/dev/null | awk '{print $3}')"
if [[ -z "$bundle_commit" ]]; then
  bundle_commit="$(git -C "$BUILD_ROOT/cycles" ls-tree HEAD lib/linux_x86_64 2>/dev/null | awk '{print $3}')"
fi

if [[ -n "$bundle_commit" ]]; then
  # --- pinned bundle epoxy (v4.1.1+) --------------------------------------
  # The bundle is LFS-materialized; git-lfs may be absent on some bases.
  if ! command -v git-lfs >/dev/null 2>&1; then
    dnf install -y git-lfs
  fi

  git clone --filter=blob:none "$CYCLES_LIB_URL" "$BUILD_ROOT/lib-linux_x64"
  git -C "$BUILD_ROOT/lib-linux_x64" checkout --detach "$bundle_commit"
  git -C "$BUILD_ROOT/lib-linux_x64" lfs install --skip-repo
  git -C "$BUILD_ROOT/lib-linux_x64" lfs pull -I 'epoxy/**'

  # The bundle's epoxy is a static archive + headers; install into /usr/local
  # (system-wide like GL, nowhere near the /opt/cycles tree). The clone is
  # throwaway and removed below, so this moves rather than duplicates. cp of a
  # missing source fails the build, so no prior layout check is needed.
  bundle_epoxy="$BUILD_ROOT/lib-linux_x64/epoxy"
  cp -a "$bundle_epoxy/include/." "$ASWF_INSTALL_PREFIX/include/"
  cp -a "$bundle_epoxy/lib/." "$ASWF_INSTALL_PREFIX/lib/"
  echo "Using pinned bundle libepoxy from lib-linux_x64@$bundle_commit"
else
  # --- no bundle: the distro package (v4.0.x and older) --------------------
  # These tags predate the lib/linux_x64 submodule, so there is no pinned epoxy
  # to take. Nothing is copied: v4.0.x's external_libs.cmake only sets
  # CMAKE_IGNORE_PATH inside its bundle branch, so with no bundle it leaves the
  # system paths searchable and FindEpoxy resolves epoxy/gl.h + the library
  # from the distro locations as installed. Leaving the file where the distro
  # put it also keeps one copy, owned by rpm, already in the loader cache.
  dnf install -y libepoxy-devel
  rpm -q libepoxy-devel libepoxy
  echo "Using distro libepoxy (no lib/linux* submodule in $CYCLES_TAG)"
fi

# Keep the build bundle-free for real. external_libs.cmake enters its precompiled
# branch when ${CMAKE_SOURCE_DIR}/../lib/<platform> exists and then hides every
# system path, so a stray sibling `lib/` would silently reintroduce the bundle.
if [[ -e "$BUILD_ROOT/lib" ]]; then
  echo "ERROR: $BUILD_ROOT/lib exists — would make Cycles use a precompiled bundle" >&2
  exit 1
fi

# WITH_LIBS_PRECOMPILED only exists from v4.3.0 on. On older tags the equivalent
# behaviour is implicit: external_libs.cmake picks its precompiled branch only
# when a sibling ../lib directory exists (asserted absent above), and with no
# bundle it never sets CMAKE_IGNORE_PATH, so system paths stay searchable.
# Passing the flag to a tag that does not define it is only a "manually-specified
# variables were not used" warning, so gate it to keep the configure log clean.
cmake_opts=()
if grep -q "WITH_LIBS_PRECOMPILED" "$BUILD_ROOT/cycles/CMakeLists.txt"; then
  cmake_opts+=(-DWITH_LIBS_PRECOMPILED=OFF)
fi
# On an older tag the array is empty. ${cmake_opts[@]} on an empty array is an
# unbound-variable error under `set -u` before bash 4.4, so guard the expansion
# by counting instead of padding with an empty argument cmake would warn about.
if [[ ${#cmake_opts[@]} -gt 0 ]]; then
  cmake_pre=("${cmake_opts[@]}")
else
  cmake_pre=()
fi

(
  cd "$BUILD_ROOT/cycles"

  cmake -B ./build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$CYCLES_INSTALL_PREFIX" \
    -DCMAKE_PREFIX_PATH="$ASWF_INSTALL_PREFIX" \
    -DPXR_ROOT="$ASWF_INSTALL_PREFIX" \
    -DCMAKE_PROJECT_INCLUDE=/usr/local/share/cycles/import_openusd_dependencies.cmake \
    -DWITH_CYCLES_OSL=OFF \
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
    -DWITH_CYCLES_DEVICE_OPTIX=OFF \
    ${cmake_pre[@]+"${cmake_pre[@]}"}

  cmake --build ./build -j"$(nproc)"
  cmake --install ./build
)

rm -rf "$BUILD_ROOT"
