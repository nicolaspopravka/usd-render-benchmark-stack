#!/usr/bin/env bash
# Manual check: tests/test_usd_deps.sh <image>.
# Requires Docker and an ASWF image; compiles consumers, runs them and checks ldd -r.
set -uo pipefail

IMAGE="${1:-}"
if [[ -z "$IMAGE" ]]; then
  echo "usage: $0 <image>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="${ROOT}/build-support/aswf_usd_deps.cmake"

if [[ ! -f "$MODULE" ]]; then
  echo "FAIL: module not found at ${MODULE}" >&2
  exit 1
fi

readonly WORKDIR=/tmp/aswf-usd-deps-test
readonly MAIN_CPP='
#include <OpenColorIO/OpenColorIO.h>
#include <OpenEXR/ImfRgbaFile.h>
#include <OpenImageIO/imageio.h>
#include <Imath/half.h>
#include <cstdio>
namespace OCIO = OCIO_NAMESPACE;
int main()
{
    OCIO::ConstConfigRcPtr config = OCIO::GetCurrentConfig();
    const int colorSpaces = config ? config->getNumColorSpaces() : -1;
    const half h(1.5f);
    const OIIO::ImageSpec spec(4, 4, 3, OIIO::TypeDesc::FLOAT);
    std::printf("colorSpaces=%d half=%.1f channels=%d\n",
                colorSpaces, static_cast<float>(h), spec.nchannels);
    // half is the symbol that the bare OpenEXR target drops off the link
    // line, so a successful run is the Imath fix proving itself.
    return (colorSpaces > 0 && h > 0.0f && spec.nchannels == 3) ? 0 : 1;
}
'

readonly CMAKE_LISTS='cmake_minimum_required(VERSION 3.21)
project(aswf_usd_deps_test LANGUAGES CXX)

find_package(pxr REQUIRED)

foreach(target
    Imath::Imath
    OpenColorIO::OpenColorIO
    OpenEXR::OpenEXR
    OpenImageIO::OpenImageIO
    OpenImageIO::OpenImageIO_Util
    OpenVDB::openvdb
    OpenGL::GL
    TBB::tbb)
  if(NOT TARGET ${target})
    message(FATAL_ERROR "aswf_usd_deps: ${target} is not defined")
  endif()
  get_target_property(type ${target} TYPE)
  if(type STREQUAL "INTERFACE_LIBRARY" AND NOT target MATCHES "^(Threads|OpenGL)")
    get_target_property(iface ${target} INTERFACE_LINK_LIBRARIES)
    if(NOT iface)
      message(FATAL_ERROR
          "aswf_usd_deps: ${target} is an empty INTERFACE target; the real "
          "library is installed but was not resolved")
    endif()
  endif()
  message(STATUS "aswf_usd_deps: ${target} TYPE=${type}")
endforeach()

if(NOT TARGET Threads::Threads)
  message(FATAL_ERROR "aswf_usd_deps: Threads::Threads is not defined")
endif()

add_executable(consumer main.cpp)
target_link_libraries(consumer PRIVATE
    OpenColorIO::OpenColorIO
    OpenEXR::OpenEXR
    OpenImageIO::OpenImageIO
    Imath::Imath)
'

# Force missing-config paths to exercise Imath linking and TBB SDK metadata.
readonly FALLBACK_CMAKE_LISTS='cmake_minimum_required(VERSION 3.21)
project(aswf_usd_deps_fallback LANGUAGES CXX)

set(CMAKE_DISABLE_FIND_PACKAGE_OpenEXR TRUE)
set(CMAKE_DISABLE_FIND_PACKAGE_TBB TRUE)
set(CMAKE_DISABLE_FIND_PACKAGE_OpenSubdiv TRUE)
set(CMAKE_DISABLE_FIND_PACKAGE_OpenImageIO TRUE)
include("@aswf_usd_deps@")

if(NOT TARGET OpenEXR::OpenEXR)
  message(FATAL_ERROR "aswf_usd_deps: fallback did not define OpenEXR::OpenEXR")
endif()
get_target_property(type OpenEXR::OpenEXR TYPE)
if(type STREQUAL "INTERFACE_LIBRARY")
  message(FATAL_ERROR
      "aswf_usd_deps: fallback OpenEXR::OpenEXR is an empty INTERFACE target")
endif()
get_target_property(iface OpenEXR::OpenEXR INTERFACE_LINK_LIBRARIES)
if(NOT iface MATCHES "Imath")
  message(FATAL_ERROR
      "aswf_usd_deps: fallback OpenEXR::OpenEXR drops Imath from its link "
      "interface; a consumer referencing Imath symbols will fail to link")
endif()
message(STATUS "aswf_usd_deps: fallback OpenEXR ILB=${iface}")

add_executable(fallback main.cpp)
get_target_property(tbb_include TBB::tbb INTERFACE_INCLUDE_DIRECTORIES)
if(NOT tbb_include)
  message(FATAL_ERROR "fallback TBB target lacks its SDK include directory")
endif()
target_link_libraries(fallback PRIVATE OpenEXR::OpenEXR TBB::tbb)
'

readonly FALLBACK_CPP='
#include <Imath/half.h>
#include <tbb/parallel_for.h>
int main()
{
    const half h(1.5f);
    int count = 0;
    tbb::parallel_for(0, 1, [&](int) { count = 1; });
    return h > 0.0f && count == 1 ? 0 : 1;
}
'

fail() { echo "FAIL: $*" >&2; exit 1; }


log="$(docker run --rm -v "${ROOT}/build-support:/m:ro" --entrypoint bash "$IMAGE" -c '
  set -euo pipefail
  mkdir -p '"${WORKDIR}"'
  cd '"${WORKDIR}"'
  cat > CMakeLists.txt <<'"'"'EOF'"'"'
'"${CMAKE_LISTS}"'EOF
  cat > main.cpp <<'"'"'EOF'"'"'
'"${MAIN_CPP}"'EOF
  cmake -S . -B build \
      -DPython3_ROOT_DIR=/usr/local \
      -DCMAKE_PROJECT_INCLUDE=/m/aswf_usd_deps.cmake
  cmake --build build
  ./build/consumer
  echo "--- ldd -r ---"
  ldd -r ./build/consumer

  mkdir -p fallback
  cd fallback
  cat > CMakeLists.txt <<'"'"'EOF'"'"'
'"${FALLBACK_CMAKE_LISTS//@aswf_usd_deps@//m/aswf_usd_deps.cmake}"'EOF
  cat > main.cpp <<'"'"'EOF'"'"'
'"${FALLBACK_CPP}"'EOF
  cmake -S . -B build
  cmake --build build
  ./build/fallback
' 2>&1)" || { echo "$log"; fail "configure/build/run failed"; }


grep -q 'colorSpaces=' <<<"$log" || fail "consumer produced no output"
loader_log="$(awk '/^--- ldd -r ---$/ {inside=1; next} inside && /^--/ {exit} inside {print}' <<<"$log")"
grep -qE 'not found|undefined symbol' <<<"$loader_log" && fail "ldd -r reported unresolved symbols"

for target in Imath OpenColorIO OpenEXR OpenImageIO; do
  grep -q "lib${target}" <<<"$log" || fail "${target} absent from the linked image"
done

grep -q 'channels=3' <<<"$log" || fail "consumer did not run to completion"
grep -q 'aswf_usd_deps: fallback OpenEXR ILB' <<<"$log" \
  || fail "fallback path did not report a link interface"

echo "PASS: real targets resolved and linked; fallback keeps Imath on OpenEXR; ldd -r clean"
