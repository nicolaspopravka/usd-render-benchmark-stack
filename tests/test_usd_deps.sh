#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Acceptance test for cmake/aswf_usd_deps.cmake.
#
# The module's whole purpose is to make a consumer link against the REAL
# libraries the ASWF conan deploy ships, so the test is a link test, not a
# configure test: every earlier failure of this mechanism (empty targets,
# the "DSO missing from command line" link error, the OpenImageIO export-set
# rejection) either configures cleanly and fails later, or fails only for one
# delegate. A configure-only test would have passed the broken versions.
#
# Run against an image that already carries the delegate under test:
#   tests/test_usd_deps.sh [image]
#
# Free: no network, no build, no pod. Needs docker and an image with the ASWF
# conan deploy (any usd-render-benchmark-stack tag, or aswf/ci-vfxall).

set -uo pipefail

IMAGE="${1:-}"
if [[ -z "$IMAGE" ]]; then
  echo "usage: $0 <image>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="${ROOT}/cmake/aswf_usd_deps.cmake"

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
    OpenGL::GL)
  if(NOT TARGET ${target})
    message(FATAL_ERROR "aswf_usd_deps: ${target} is not defined")
  endif()
  get_target_property(type ${target} TYPE)
  # Threads and OpenGL are modelled as INTERFACE targets that carry flags, and
  # on a glibc base Threads::Threads is legitimately empty because pthreads is
  # part of libc. Every other target must resolve to a real library, because an
  # empty INTERFACE there is the defect this module exists to prevent.
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

# Present but hollow is the failure mode; Threads must merely exist, since
# glibc makes an empty Threads::Threads correct.
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

# The fallback path. On a base that ships a real OpenEXR config, OpenEXR's own
# export set already carries Imath::Imath and the module's step 4 is a no-op,
# so the passing case above does not actually test that step. Disabling the
# package forces the location fallback FindUSDPixar uses when a base has the
# library but no config, which is exactly where Imath would silently drop off
# the link line and bin/cycles would fail to link.
readonly FALLBACK_CMAKE_LISTS='cmake_minimum_required(VERSION 3.21)
project(aswf_usd_deps_fallback LANGUAGES CXX)

set(CMAKE_DISABLE_FIND_PACKAGE_OpenEXR TRUE)
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
target_link_libraries(fallback PRIVATE OpenEXR::OpenEXR)
'

# Only Imath and the OpenEXR fallback are in play here, so the source is
# trimmed to the symbol whose resolution is actually being asserted.
readonly FALLBACK_CPP='
#include <Imath/half.h>
int main()
{
    const half h(1.5f);
    return h > 0.0f ? 0 : 1;
}
'

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== aswf_usd_deps acceptance against ${IMAGE}"

# The module is mounted read-only and used from /m, so the test exercises the
# committed file rather than a copy that could drift from it.
log="$(docker run --rm -v "${ROOT}/cmake:/m:ro" --entrypoint bash "$IMAGE" -c '
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

echo "$log" | sed -n 's/^-- aswf_usd_deps: /  target: /p'

grep -q 'colorSpaces=' <<<"$log" || fail "consumer produced no output"
grep -qE 'not found|undefined symbol' <<<"$log" && fail "ldd -r reported unresolved symbols"

for target in Imath OpenColorIO OpenEXR OpenImageIO; do
  grep -q "lib${target}" <<<"$log" || fail "${target} absent from the linked image"
done

# The consumer exits 0 only when OCIO answered, half round-tripped and OIIO
# reported its channels; a link that silently dropped Imath fails at runtime.
grep -q 'channels=3' <<<"$log" || fail "consumer did not run to completion"
grep -q 'aswf_usd_deps: fallback OpenEXR ILB' <<<"$log" \
  || fail "fallback path did not report a link interface"

echo "PASS: real targets resolved and linked; fallback keeps Imath on OpenEXR; ldd -r clean"