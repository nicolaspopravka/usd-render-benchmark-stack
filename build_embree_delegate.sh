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
# Embree comes EXCLUSIVELY from the image: the ASWF conan stack builds
# embree into /usr/local (the ci-moonray dependency set, May-Jun 2026).  No
# Embree is downloaded or built here ("always use the embree shipped in the
# image" -- Nicolas, Sep 11 2026).
#
# Compatibility probe: OpenUSD's in-tree hdEmbree targets one embree family
# per release -- < embree3/rtcore.h > on 23.08-25.05.01, < embree4/rtcore.h >
# on 26.03/26.08.  The shipped conan package provides ONLY the embree4
# family (include/embree4 + libembree4.so.4).  Years whose hdEmbree requires
# embree3 therefore FAIL the probe with a documented diagnostic: the shipped
# embree cannot build hdEmbree against the shipped OpenUSD on that year --
# an upstream (aswf-docker) gap, surfaced here rather than papered over by a
# separate embree3 build.

readonly OPENUSD_URL="https://github.com/PixarAnimationStudios/OpenUSD.git"
readonly BUILD_ROOT=/opt/build
readonly EVIDENCE_ROOT=/usr/local/aswf/embree-evidence
readonly USD_PREFIX=/usr/local
readonly CONSUMER_DIR=/usr/local/share/hdembree-consumer
readonly PLUGIN_ROOT=/usr/local/plugin/usd

# --- pinned revisions (Pixar build_usd.py Linux pairings; collected 2026-08-29) ---
openusd_pins() {
  case "$1" in
    0.23.8)
      readonly OPENUSD_TAG=v23.08
      readonly OPENUSD_REVISION=10b62439e9242a55101cf8b200f2c7e02420e1b0 ;;
    0.24.8)
      readonly OPENUSD_TAG=v24.08
      readonly OPENUSD_REVISION=59992d2178afcebd89273759f2bddfe730e59aa8 ;;
    0.25.5)
      readonly OPENUSD_TAG=v25.05.01
      readonly OPENUSD_REVISION=1595c62ea8381b5b22eb8621afc8652f89b6136d ;;
    0.26.3)
      readonly OPENUSD_TAG=v26.03
      readonly OPENUSD_REVISION=1818e14bae0036ac4bc7b4e60826b5797076a4fe ;;
    0.26.8)
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

readonly BUILD_JOBS="${EMBREE_BUILD_JOBS:-$(nproc)}"
mkdir -p "$BUILD_ROOT" "$EVIDENCE_ROOT" "$CONSUMER_DIR"

# --- the shipped (conan) Embree: use it and only it -------------------------
# ASWF's conan stack builds embree 4.2.0 into /usr/local (ci-moonray dep set).
shipped_embree_lib="$(ls /usr/local/lib/libembree4.so.4 2>/dev/null || true)"
shipped_embree_header=/usr/local/include/embree4/rtcore.h
test -n "$shipped_embree_lib"
test -f "$shipped_embree_header"
test -d /usr/local/lib/cmake/embree-*
printf 'shipped Embree: %s\n' "$shipped_embree_lib" \
  | tee "$EVIDENCE_ROOT/shipped-embree.txt"
ldd -r /usr/local/lib/libembree4.so.4 | tee "$EVIDENCE_ROOT/libembree4-ldd.txt"

# --- verify the pxr installation we are consuming ---------------------------
test -d "$USD_PREFIX/include/pxr"
test -d "$USD_PREFIX/include/pxr/imaging/hdx"
test -d "$USD_PREFIX/lib"
test -x "$USD_PREFIX/bin/usdrecord"
test -f "$PLUGIN_ROOT/plugInfo.json"

# pxr version from the installed header (no pxr import -- import SIGILLs on
# AVX2-only hosts for the prebuilt 2023-26 libs).
usd_version="$(sed -n \
  's/^#define PXR_MAJOR_VERSION \([0-9]*\)$/\1/p; s/^#define PXR_MINOR_VERSION \([0-9]*\)$/\1/p; s/^#define PXR_PATCH_VERSION \([0-9]*\)$/\1/p' \
  "$USD_PREFIX/include/pxr/pxr.h" | paste -sd. -)"
printf '%s\n' "$usd_version" | tee "$EVIDENCE_ROOT/openusd-version.txt"
openusd_pins "$usd_version"

find "$USD_PREFIX/lib" -maxdepth 1 -name 'libusd_*.so*' -printf '%f\n' | sort \
  > "$EVIDENCE_ROOT/openusd-libraries.txt"

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

# --- compatibility probe: does the shipped embree family match the plugin? --
required_embree="$(grep -rhoE '#include <embree[0-9]/rtcore\.h>' \
  "$HDEMBREE_SOURCE_DIR" | grep -oE 'embree[0-9]' | sort -u | head -1)"
test -n "$required_embree"
printf 'required Embree family: %s (OpenUSD %s)\n' "$required_embree" "$usd_version" \
  | tee "$EVIDENCE_ROOT/required-embree.txt"
if [[ "$required_embree" != "embree4" ]]; then
  {
    echo "ERROR: upstream compat gap -- the shipped conan Embree cannot build hdEmbree"
    echo "against the shipped OpenUSD on this year ($usd_version)."
    echo ""
    echo "OpenUSD $usd_version's in-tree hdEmbree requires $required_embree"
    echo "  (pxr/imaging/plugin/hdEmbree/context.h: #include <${required_embree}/rtcore.h>),"
    echo "but the ASWF image ships conan Embree 4.2.0 ONLY:"
    echo "  lib:     /usr/local/lib/libembree4.so.4 (no libembree[3].so*)"
    echo "  headers: /usr/local/include/embree4/ (no include/${required_embree}/)"
    echo "The ASWF-created embree 4.2.0 conan package (ci-moonray dep set, May-Jun"
    echo "2026) is unusable to build hdEmbree on the years the shipped OpenUSD needs"
    echo "embree3. As-fixed: building a separate Embree 3.x here is rejected by design"
    echo "(\"always use the embree shipped in the image\"). Candidate aswf-docker"
    echo "upstream finding."
  } | tee "$EVIDENCE_ROOT/compat-probe-failure.txt"
  exit 1
fi
readonly EMBREE_LIBRARY_FILE=/usr/local/lib/libembree4.so
test -e "$EMBREE_LIBRARY_FILE"

# --- consumer build (direct linkage, hdCycles pattern) ----------------------
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
#
# Embree is the image's shipped conan embree4 (libembree4 + embree4 headers).
# The caller presets EMBREE_LIBRARY (-D) so the era-appropriate library is
# forced: find_library(embree4 embree3) would name-order to whatever exists
# first, and the plugin's required family is decided by the compat probe.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(HDEMBREE_SOURCE_DIR "" CACHE PATH
    "Directory of the upstream hdEmbree plugin sources inside an OpenUSD checkout")
set(EMBREE_ROOT "/usr/local" CACHE PATH "Embree install prefix (shipped conan embree)")
set(USD_INCLUDE_DIR "/usr/local/include" CACHE PATH "Prebuilt OpenUSD headers")
set(USD_LIB_DIR "/usr/local/lib" CACHE PATH "Prebuilt OpenUSD libraries")

if(NOT HDEMBREE_SOURCE_DIR)
  message(FATAL_ERROR "HDEMBREE_SOURCE_DIR is required")
endif()

if(NOT EMBREE_LIBRARY)
  find_library(EMBREE_LIBRARY
    NAMES embree4 embree3
    PATHS "${EMBREE_ROOT}/lib"
    NO_DEFAULT_PATH)
endif()
if(NOT EMBREE_LIBRARY)
  message(FATAL_ERROR "Cannot locate the Embree library under ${EMBREE_ROOT}/lib")
endif()
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
  -DEMBREE_LIBRARY="$EMBREE_LIBRARY_FILE" \
  -DCMAKE_INSTALL_RPATH=/usr/local/lib

cmake --build "$BUILD_ROOT/hdembree-build" -j"$BUILD_JOBS"
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
grep -Eq 'libembree4' "$EVIDENCE_ROOT/hdEmbree-ldd.txt"

readelf -d "$PLUGIN_ROOT/hdEmbree.so" | tee "$EVIDENCE_ROOT/hdEmbree-dynamic.txt"
grep -q "/usr/local/lib" "$EVIDENCE_ROOT/hdEmbree-dynamic.txt"

# --- the key gate: default discovery with NO PXR_PLUGINPATH_NAME ------------
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
  printf 'OpenUSD prefix: %s\n' "$USD_PREFIX"
  printf 'Embree source: shipped ASWF conan embree4 (no tarball build)\n'
  printf 'Installed: %s\n' "$PLUGIN_ROOT"
  printf 'Compiler: '
  gcc --version | head -1
  printf 'CMake: '
  cmake --version | head -1
} > "$EVIDENCE_ROOT/source-revisions.txt"

rm -rf "$BUILD_ROOT"