#!/usr/bin/env bash
set -euxo pipefail

# Build hdEmbree as an external consumer of the image's prebuilt OpenUSD and
# install it where a USD build with hdEmbree enabled would have put it:
#
#   /usr/local/plugin/usd/hdEmbree.so                      (sibling of hdStorm.so)
#   /usr/local/plugin/usd/hdEmbree/resources/plugInfo.json (leaf plugInfo)
#
# The base already ships /usr/local/plugin/usd/plugInfo.json = { "Includes":
# ["*/resources/"] }, which picks up the new leaf automatically, and
# /usr/local/plugin/usd is a compiled-in plugin search root of the conan
# OpenUSD (verified: plain docker run enumerates hdStorm with PXR_PLUGINPATH_NAME
# unset).  So NO PXR_PLUGINPATH_NAME is set anywhere -- discovery is exactly
# as if the ASWF USD build had enabled hdEmbree.
#
# One USD build per image is a hard requirement: no second USD prefix is
# built; this consumes whatever OpenUSD the base image ships (hdCycles/
# hdStorm external-consumer pattern, direct linkage -- the conan pxrConfig
# bakes dead conan-home paths, so find_package(pxr) is never used).
#
# Embree era is driven by the base's USD version (from pxr.Usd.GetVersion()):
#   USD < 26.x (23.08/24.08/25.05.01): the hdEmbree of those releases uses
#     the embree3 API -> build the pinned Embree 3.2.2 (Pixar build_usd.py
#     pairing) into /usr/local and link it.
#   USD >= 26.x (26.03/26.08): the plugin supports embree4 -> link the conan
#     Embree 4.2.0 the base already ships at /usr/local (the integrated
#     dependency an ASWF-enabled build would use).
# The 3.x pairing also vendors legacy TBB 2020.3.1 (libtbb.so.2) when the
# base does not already provide it, mirroring build_usd.py InstallTBB_Linux.

readonly OPENUSD_URL="https://github.com/PixarAnimationStudios/OpenUSD.git"
readonly BUILD_ROOT=/opt/build
readonly EVIDENCE_ROOT=/usr/local/aswf/embree-evidence
readonly USD_PREFIX=/usr/local
readonly CONSUMER_DIR=/usr/local/share/hdembree-consumer
readonly PLUGIN_ROOT=/usr/local/plugin/usd

# --- pinned revisions (Pixar build_usd.py Linux pairings; collected 2026-08-29) ---
readonly EMBREE3_TAG=v3.2.2
readonly EMBREE3_REVISION=dac0fa9d4a55d0ab0456d332bd0f23fd8a3325bc
readonly EMBREE3_TARBALL_SHA256=f0523819aa24f77608afde3d23ddbeaea88937e3f9fb6a115c23e0e0646c8f5f
readonly TBB_TAG=v2020.3.1
readonly TBB_REVISION=617e9a711b713de9f33c2be1323cc5cebff0e850
readonly TBB_TARBALL_SHA256=ad73e88dbf8590daa66136275d0785e5a733d0ee2cc66b99f210bdc969302b7d

openusd_pins() {
  case "$1" in
    23.08)
      readonly OPENUSD_TAG=v23.08
      readonly OPENUSD_REVISION=10b62439e9242a55101cf8b200f2c7e02420e1b0 ;;
    24.08)
      readonly OPENUSD_TAG=v24.08
      readonly OPENUSD_REVISION=59992d2178afcebd89273759f2bddfe730e59aa8 ;;
    25.05.01)
      readonly OPENUSD_TAG=v25.05.01
      readonly OPENUSD_REVISION=1595c62ea8381b5b22eb8621afc8652f89b6136d ;;
    26.03)
      readonly OPENUSD_TAG=v26.03
      readonly OPENUSD_REVISION=1818e14bae0036ac4bc7b4e60826b5797076a4fe ;;
    26.08)
      readonly OPENUSD_TAG=v26.08
      readonly OPENUSD_REVISION=ee47c679abde5b467a7b6a41f3b2285564a4222e ;;
    *)
      echo "ERROR: unsupported OpenUSD version '$1' in the base image" >&2
      exit 1 ;;
  esac
}

if [[ -n "${ASWF_DTS_VERSION:-}" && -e "/opt/rh/gcc-toolset-${ASWF_DTS_VERSION}/enable" ]]; then
  # shellcheck disable=SC1090
  source "/opt/rh/gcc-toolset-${ASWF_DTS_VERSION}/enable"
else
  toolset="$(find /opt/rh -maxdepth 1 -type d -name 'gcc-toolset-*' | sort -V | tail -1)"
  if [[ -n "$toolset" ]]; then
    # shellcheck disable=SC1090
    source "$toolset/enable"
  fi
fi
command -v git >/dev/null 2>&1 || {
  dnf install -y git
  dnf clean all
  rm -rf /var/cache/dnf
}

mkdir -p "$BUILD_ROOT" "$EVIDENCE_ROOT" "$CONSUMER_DIR"

# --- verify the pxr installation we are consuming ---------------------------
test -d "$USD_PREFIX/include/pxr"
test -d "$USD_PREFIX/include/pxr/imaging/hdx"
test -d "$USD_PREFIX/lib"
test -x "$USD_PREFIX/bin/usdrecord"
test -f "$PLUGIN_ROOT/plugInfo.json"

usd_python_dir=""
for candidate in \
  "$USD_PREFIX/lib/python3.13/site-packages" \
  "$USD_PREFIX/lib/python3.12/site-packages" \
  "$USD_PREFIX/lib/python3.11/site-packages" \
  "$USD_PREFIX/lib/python3.10/site-packages" \
  "$USD_PREFIX/lib/python" \
; do
  if [[ -d "$candidate/pxr" ]]; then
    usd_python_dir="$candidate"
    break
  fi
done
test -n "$usd_python_dir"
test -d "$usd_python_dir/pxr"

usd_version="$(PYTHONPATH="$usd_python_dir${PYTHONPATH:+:$PYTHONPATH}" \
  python3 -c 'from pxr import Usd; v=Usd.GetVersion(); print("%d.%d.%d" % v)')"
printf '%s\n' "$usd_version" | tee "$EVIDENCE_ROOT/openusd-version.txt"
openusd_pins "$usd_version"
readonly EMBREE3_BUILD=$([[ "${usd_version%%.*}" -lt 26 ]] && echo 1 || echo 0)
printf 'Embree 3.x build required: %s\n' "$EMBREE3_BUILD" \
  | tee "$EVIDENCE_ROOT/embree3-build-flag.txt"

find "$USD_PREFIX/lib" -maxdepth 1 -name 'libusd_*.so*' -printf '%f\n' | sort \
  > "$EVIDENCE_ROOT/openusd-libraries.txt"

# --- Embree: build 3.2.2 (USD < 26) into /usr/local, or use the base's conan 4.2.0 ---
if [[ "$EMBREE3_BUILD" == "1" ]]; then
  tarball="$BUILD_ROOT/embree-${EMBREE3_TAG}.tar.gz"
  curl -fsSL --retry 5 -o "$tarball" \
    "https://github.com/RenderKit/embree/archive/refs/tags/${EMBREE3_TAG}.tar.gz"
  echo "${EMBREE3_TARBALL_SHA256}  ${tarball}" | sha256sum --check --strict \
    | tee "$EVIDENCE_ROOT/embree-sha256-check.txt"

  mkdir -p "$BUILD_ROOT/embree-src"
  tar -xzf "$tarball" --strip-components=1 -C "$BUILD_ROOT/embree-src"
  IFS='.' read -r EVMAJOR EVMINOR EVPATCH <<< "${EMBREE3_TAG#v}"
  grep -m1 "SET(EMBREE_VERSION_MAJOR ${EVMAJOR})" "$BUILD_ROOT/embree-src/CMakeLists.txt" \
    | tee "$EVIDENCE_ROOT/embree-version-line.txt"
  grep -m1 "SET(EMBREE_VERSION_MINOR ${EVMINOR})" "$BUILD_ROOT/embree-src/CMakeLists.txt" \
    | tee -a "$EVIDENCE_ROOT/embree-version-line.txt"
  grep -m1 "SET(EMBREE_VERSION_PATCH ${EVPATCH})" "$BUILD_ROOT/embree-src/CMakeLists.txt" \
    | tee -a "$EVIDENCE_ROOT/embree-version-line.txt"

  # Legacy TBB 2020.3.1 for the embree3 pairing.  Build against a stage for
  # determinism (matches build_usd.py InstallTBB_Linux), but only install
  # into /usr/local when the base does not already ship libtbb.so.2
  # (2023/24 bases do; 2025 has oneTBB .12 only).
  tbb_tarball="$BUILD_ROOT/tbb-${TBB_TAG}.tar.gz"
  curl -fsSL --retry 5 -o "$tbb_tarball" \
    "https://github.com/oneapi-src/oneTBB/archive/refs/tags/${TBB_TAG}.tar.gz"
  echo "${TBB_TARBALL_SHA256}  ${tbb_tarball}" | sha256sum --check --strict \
    | tee "$EVIDENCE_ROOT/tbb-sha256-check.txt"

  mkdir -p "$BUILD_ROOT/tbb-src"
  tar -xzf "$tbb_tarball" --strip-components=1 -C "$BUILD_ROOT/tbb-src"
  make -C "$BUILD_ROOT/tbb-src" -j"$(nproc)" tbb tbbmalloc

  TBB_STAGE="$BUILD_ROOT/tbb-stage"
  mkdir -p "$TBB_STAGE/include" "$TBB_STAGE/lib"
  cp -a "$BUILD_ROOT/tbb-src/include/tbb" "$TBB_STAGE/include/"
  cp -a "$BUILD_ROOT/tbb-src/build/"*_release/libtbb*.so.* "$TBB_STAGE/lib/"
  for l in libtbb libtbbmalloc libtbbmalloc_proxy; do
    ln -sf "$l.so.2" "$TBB_STAGE/lib/$l.so"
  done
  test -f "$TBB_STAGE/include/tbb/task_scheduler_init.h"
  test -e "$TBB_STAGE/lib/libtbb.so.2"
  test -e "$TBB_STAGE/lib/libtbb.so"

  cmake -S "$BUILD_ROOT/embree-src" -B "$BUILD_ROOT/embree-build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$USD_PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_RPATH=/usr/local/lib \
    -DEMBREE_TUTORIALS=OFF \
    -DEMBREE_ISPC_SUPPORT=OFF \
    -DEMBREE_TBB_ROOT="$TBB_STAGE"
  cmake --build "$BUILD_ROOT/embree-build" -j"$(nproc)"
  cmake --install "$BUILD_ROOT/embree-build"
  test -e "$USD_PREFIX/lib/libembree3.so.3"

  # Ship the vendored legacy TBB for the embree3 link closure only where the
  # base lacks libtbb.so.2 (2023/24 already have it).
  if [[ ! -e /usr/local/lib/libtbb.so.2 ]]; then
    cp -a "$TBB_STAGE"/lib/libtbb*.so.* /usr/local/lib/
  fi

  cp "$BUILD_ROOT/embree-build/CMakeCache.txt" "$EVIDENCE_ROOT/Embree-CMakeCache.txt"
  find "$USD_PREFIX/lib" -maxdepth 1 -name 'libembree3*' -o -maxdepth 1 -name 'libtbb.so.2*' \
    | sort > "$EVIDENCE_ROOT/embree-install-manifest.txt"
  ldd -r /usr/local/lib/libembree3.so.3 | tee "$EVIDENCE_ROOT/libembree3-ldd.txt"
  grep -Eq 'libtbb\.so\.2' "$EVIDENCE_ROOT/libembree3-ldd.txt"
else
  # USD >= 26: link the base's conan Embree 4.2.0 (the integrated dep an
  # ASWF-enabled build would use).  Assert it is present and usable.
  test -f /usr/local/lib/libembree4.so
  test -f /usr/local/include/embree4/rtcore.h
  ldd -r /usr/local/lib/libembree4.so.4 | tee "$EVIDENCE_ROOT/libembree4-ldd.txt"
fi

# --- pinned OpenUSD checkout (sources pristine) -----------------------------
cd "$BUILD_ROOT"
git clone --branch "$OPENUSD_TAG" --depth 1 "$OPENUSD_URL" openusd
test "$(git -C openusd rev-parse HEAD)" = "$OPENUSD_REVISION"
test -z "$(git -C openusd status --short)"
git -C openusd diff > "$EVIDENCE_ROOT/openusd-applied.patch"
test ! -s "$EVIDENCE_ROOT/openusd-applied.patch"

HDEMBREE_SOURCE_DIR="$BUILD_ROOT/openusd/pxr/imaging/plugin/hdEmbree"
test -d "$HDEMBREE_SOURCE_DIR"
ls "$HDEMBREE_SOURCE_DIR" | tee "$EVIDENCE_ROOT/hdembree-source-listing.txt"

# --- consumer build ----------------------------------------------------------
cat > "$CONSUMER_DIR/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.21)
project(hdembree-consumer LANGUAGES CXX)

# External consumer build of hdEmbree (hdCycles pattern): compile upstream
# hdEmbree plugin sources against the base's prebuilt OpenUSD by DIRECT
# LINKAGE and install into the compiled-in plugin root
# (<USD_PREFIX>/plugin/usd), exactly where a USD build with hdEmbree enabled
# would put it.  The base ships /usr/local/plugin/usd/plugInfo.json =
# {"Includes": ["*/resources/"]}, which auto-discovers the installed leaf.
#
#   <prefix>/plugin/usd/hdEmbree.so
#   <prefix>/plugin/usd/hdEmbree/resources/plugInfo.json

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(HDEMBREE_SOURCE_DIR "" CACHE PATH
    "Directory of the upstream hdEmbree plugin sources inside an OpenUSD checkout")
set(EMBREE_ROOT "/usr/local" CACHE PATH "Embree install prefix")
set(USD_INCLUDE_DIR "/usr/local/include" CACHE PATH "Prebuilt OpenUSD headers")
set(USD_LIB_DIR "/usr/local/lib" CACHE PATH "Prebuilt OpenUSD libraries")

if(NOT HDEMBREE_SOURCE_DIR)
  message(FATAL_ERROR "HDEMBREE_SOURCE_DIR is required")
endif()

find_library(EMBREE_LIBRARY
  NAMES embree4 embree3
  PATHS "${EMBREE_ROOT}/lib"
  NO_DEFAULT_PATH
  REQUIRED)
message(STATUS "Embree library: ${EMBREE_LIBRARY}")

set(HDEMBREE_PXR_LIBS plug tf vt gf work hf hd hdx)
set(_split_paths "")
set(_missing "")
foreach(_name IN LISTS HDEMBREE_PXR_LIBS)
  find_library(_pxr_lib
    NAMES "usd_${_name}" "${_name}"
    PATHS "${USD_LIB_DIR}"
    NO_DEFAULT_PATH)
  if(_pxr_lib)
    list(APPEND _split_paths "${_pxr_lib}")
  else()
    list(APPEND _missing "${_name}")
  endif()
  unset(_pxr_lib CACHE)
endforeach()

if(_missing)
  find_library(_pxr_ms
    NAMES usd_ms
    PATHS "${USD_LIB_DIR}"
    NO_DEFAULT_PATH)
  if(NOT _pxr_ms)
    message(FATAL_ERROR
      "Cannot locate prebuilt OpenUSD libraries (missing: ${_missing}; "
      "no monolithic libusd_ms.so in ${USD_LIB_DIR})")
  endif()
  set(HDEMBREE_LINK_LIBRARIES "${_pxr_ms}")
  message(STATUS "OpenUSD monolithic library: ${_pxr_ms}")
else()
  set(HDEMBREE_LINK_LIBRARIES "${_split_paths}")
  foreach(_p IN LISTS _split_paths)
    message(STATUS "OpenUSD split library: ${_p}")
  endforeach()
endif()

find_library(HDEMBREE_TBB_LIBRARY
  NAMES tbb
  PATHS "${USD_LIB_DIR}" /usr/local/lib)
message(STATUS "TBB library: ${HDEMBREE_TBB_LIBRARY}")

set(IMAGE_PYTHON_EXECUTABLE "/usr/local/bin/python3")
execute_process(
  COMMAND "${IMAGE_PYTHON_EXECUTABLE}" -c
    "import sysconfig; print(sysconfig.get_config_var('INCLUDEPY'))"
  RESULT_VARIABLE _pyinc_rc
  OUTPUT_VARIABLE _pyinc
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_QUIET)
if(NOT _pyinc_rc EQUAL 0 OR NOT _pyinc OR NOT EXISTS "${_pyinc}")
  file(GLOB _pyinc "${USD_INCLUDE_DIR}/python3*")
  list(LENGTH _pyinc _pyinc_len)
  if(NOT _pyinc_len EQUAL 1)
    message(FATAL_ERROR
      "Cannot locate the Python include dir (pyconfig.h) for wrap_python.hpp")
  endif()
  list(GET _pyinc 0 _pyinc)
endif()
set(PYTHON_INCLUDE_DIR "${_pyinc}")
message(STATUS "Python include dir: ${PYTHON_INCLUDE_DIR}")

file(GLOB_RECURSE HDEMBREE_SOURCES CONFIGURE_DEPENDS "${HDEMBREE_SOURCE_DIR}/*.cpp")
list(LENGTH HDEMBREE_SOURCES HDEMBREE_SOURCE_COUNT)
if(HDEMBREE_SOURCE_COUNT EQUAL 0)
  message(FATAL_ERROR "No hdEmbree sources under ${HDEMBREE_SOURCE_DIR}")
endif()
message(STATUS "hdEmbree sources: ${HDEMBREE_SOURCE_COUNT}")

add_library(hdEmbree SHARED ${HDEMBREE_SOURCES})
set_target_properties(hdEmbree PROPERTIES PREFIX "")

target_include_directories(hdEmbree PRIVATE
  "${USD_INCLUDE_DIR}"
  "${PYTHON_INCLUDE_DIR}"
  "${HDEMBREE_SOURCE_DIR}/../../../.."
  "${EMBREE_ROOT}/include")

target_link_libraries(hdEmbree PRIVATE
  ${HDEMBREE_LINK_LIBRARIES}
  ${HDEMBREE_TBB_LIBRARY}
  ${EMBREE_LIBRARY})

target_compile_definitions(hdEmbree PRIVATE
  MFB_PACKAGE_NAME=hdEmbree
  MFB_ALT_PACKAGE_NAME=hdEmbree
  MFB_PACKAGE_MODULE=HdEmbree
  PXR_BUILD_LOCATION=usd
  PXR_PLUGIN_BUILD_LOCATION=../plugin/usd)

set(PLUG_INFO_ROOT "..")
set(PLUG_INFO_LIBRARY_PATH "../hdEmbree.so")
set(PLUG_INFO_RESOURCE_PATH "resources")
set(PLUG_INFO_PLUGIN_NAME "pxr.hdEmbree")
configure_file("${HDEMBREE_SOURCE_DIR}/plugInfo.json"
               "${CMAKE_CURRENT_BINARY_DIR}/plugInfo.json" @ONLY)

# Install into the compiled-in plugin root, mirroring the base's hdStorm
# layout (<root>/hdStorm.so + <root>/hdStorm/resources/plugInfo.json).  The
# base root plugInfo.json already Includes "*/resources/", so no root file
# is installed here.
install(TARGETS hdEmbree
  LIBRARY DESTINATION plugin/usd)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/plugInfo.json"
  DESTINATION plugin/usd/hdEmbree/resources)
EOF

cmake -S "$CONSUMER_DIR" -B "$BUILD_ROOT/hdembree-build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$USD_PREFIX" \
  -DUSD_INCLUDE_DIR="$USD_PREFIX/include" \
  -DUSD_LIB_DIR="$USD_PREFIX/lib" \
  -DHDEMBREE_SOURCE_DIR="$HDEMBREE_SOURCE_DIR" \
  -DEMBREE_ROOT="$USD_PREFIX" \
  -DCMAKE_INSTALL_RPATH=/usr/local/lib

cmake --build "$BUILD_ROOT/hdembree-build" -j"$(nproc)"
cmake --install "$BUILD_ROOT/hdembree-build"

# --- gates -------------------------------------------------------------------
test -f "$PLUGIN_ROOT/hdEmbree.so"
test -f "$PLUGIN_ROOT/hdEmbree/resources/plugInfo.json"
! grep -q "@PLUG_INFO" "$PLUGIN_ROOT/hdEmbree/resources/plugInfo.json"
grep -q '"Embree"' "$PLUGIN_ROOT/hdEmbree/resources/plugInfo.json"

ldd -r "$PLUGIN_ROOT/hdEmbree.so" | tee "$EVIDENCE_ROOT/hdEmbree-ldd.txt"
if grep -Eq 'not found|undefined symbol' "$EVIDENCE_ROOT/hdEmbree-ldd.txt"; then
  echo "ERROR: unresolved entries in hdEmbree.so closure:" >&2
  grep -E 'not found|undefined symbol' "$EVIDENCE_ROOT/hdEmbree-ldd.txt" | head -20 >&2
  exit 1
fi
grep -Eq 'libembree[34]' "$EVIDENCE_ROOT/hdEmbree-ldd.txt"

readelf -d "$PLUGIN_ROOT/hdEmbree.so" | tee "$EVIDENCE_ROOT/hdEmbree-dynamic.txt"
grep -q "/usr/local/lib" "$EVIDENCE_ROOT/hdEmbree-dynamic.txt"

# --- the key gate: default discovery with NO PXR_PLUGINPATH_NAME ------------
env -u PXR_PLUGINPATH_NAME \
  PYTHONPATH="$usd_python_dir${PYTHONPATH:+:$PYTHONPATH}" \
  python3 - <<'PYEOF'
from pxr import Plug
plug = Plug.Registry().GetPluginWithName("hdEmbree")
assert plug is not None, "hdEmbree not registered by default discovery"
print("hdEmbree plugin discovered via the compiled-in plugin roots (no PXR_PLUGINPATH_NAME)")
PYEOF

find "$PLUGIN_ROOT"/hdEmbree* -type f -print | sort \
  > "$EVIDENCE_ROOT/hdembree-install-manifest.txt"
cp "$BUILD_ROOT/hdembree-build/CMakeCache.txt" "$EVIDENCE_ROOT/HdEmbree-CMakeCache.txt"

{
  printf 'OpenUSD version: %s\n' "$usd_version"
  printf 'OpenUSD tag: %s\n' "$OPENUSD_TAG"
  printf 'OpenUSD revision: %s\n' "$OPENUSD_REVISION"
  printf 'Embree 3.x build: %s\n' "$EMBREE3_BUILD"
  printf 'OpenUSD prefix: %s\n' "$USD_PREFIX"
  printf 'Installed: %s\n' "$PLUGIN_ROOT"
  printf 'Compiler: '
  gcc --version | head -1
  printf 'CMake: '
  cmake --version | head -1
} > "$EVIDENCE_ROOT/source-revisions.txt"

rm -rf "$BUILD_ROOT"