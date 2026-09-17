cmake_minimum_required(VERSION 3.21)
project(hdembree-consumer LANGUAGES CXX)

# External consumer build of OpenUSD's in-tree hdEmbree plugin
# (pxr/imaging/plugin/hdEmbree): build the plugin against the base's PREBUILT
# OpenUSD via the pxr package (find_package), then install into the compiled-in
# plugin root (<prefix>/plugin/usd) -- exactly where a USD build with
# PXR_BUILD_EMBREE_PLUGIN=ON would put it. Embree always comes from the image.
# One USD build per image: nothing is rebuilt here.
#
# The ASWF deploy's pxr cmake exports reference imported targets it does not
# define (CONAN_LIB::*, OpenSubdiv::*, ...); fixers/02-openusd-cmake-exports.sh
# (a RUN step in Dockerfile.pristine) provides them before this configure runs.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# --- inputs (all cached; provided by build_hdembree.sh) --------------------
set(HDEMBREE_SOURCE_DIR "" CACHE PATH
    "Directory of the upstream hdEmbree plugin sources inside an OpenUSD checkout")
set(USD_INCLUDE_DIR "/usr/local/include" CACHE PATH "Prebuilt OpenUSD headers")
set(EMBREE_ROOT "/usr/local" CACHE PATH "Embree install prefix (shipped conan embree)")

if(NOT HDEMBREE_SOURCE_DIR)
  message(FATAL_ERROR "HDEMBREE_SOURCE_DIR is required")
endif()

# --- pxr (prebuilt OpenUSD) ---------------------------------------------------
# PXR_VERSION is set by pxrConfig; the retrieved components are links with the
# plugin's needs (hdMoonray precedent: link the plain component targets).
find_package(pxr REQUIRED)
find_package(Threads REQUIRED)
if(PXR_VERSION VERSION_LESS 2603)
  message(FATAL_ERROR "This consumer expects OpenUSD >= 26.03 on the base")
endif()

# --- Embree library ----------------------------------------------------------
# No era preselect: the shipped conan embree provides the family the plugin
# needs on the CU cycles (26.03/26.08 -> embree4); one family is present, so
# find_library name-order cannot mislink.
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

# --- TBB ----------------------------------------------------------------------
find_library(HDEMBREE_TBB_LIBRARY
  NAMES tbb
  PATHS "${EMBREE_ROOT}/lib")
message(STATUS "TBB library: ${HDEMBREE_TBB_LIBRARY}")

# --- Python include dir (for wrap_python.hpp) -----------------------------------
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

# --- pxr component targets to link ----------------------------------------------
# The pxr package defines imported targets per component (tf, plug, ...); verify
# each exists so a silent name typo fails loudly.
set(HDEMBREE_PXR_LIBS plug tf vt gf work hf hd hdx)
set(_missing "")
foreach(_name IN LISTS HDEMBREE_PXR_LIBS)
  if(NOT TARGET "${_name}")
    list(APPEND _missing "${_name}")
  endif()
endforeach()
if(_missing)
  message(FATAL_ERROR "pxr package does not define component targets: ${_missing}")
endif()

# --- sources / target -----------------------------------------------------------
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
  ${HDEMBREE_PXR_LIBS}
  ${HDEMBREE_TBB_LIBRARY}
  ${EMBREE_LIBRARY})

target_compile_definitions(hdEmbree PRIVATE
  MFB_PACKAGE_NAME=hdEmbree
  MFB_ALT_PACKAGE_NAME=hdEmbree
  MFB_PACKAGE_MODULE=HdEmbree
  PXR_BUILD_LOCATION=usd
  PXR_PLUGIN_BUILD_LOCATION=../plugin/usd)

# --- plugInfo -----------------------------------------------------------------------
set(PLUG_INFO_ROOT "..")
set(PLUG_INFO_LIBRARY_PATH "../hdEmbree.so")
set(PLUG_INFO_RESOURCE_PATH "resources")
set(PLUG_INFO_PLUGIN_NAME "pxr.hdEmbree")
configure_file("${HDEMBREE_SOURCE_DIR}/plugInfo.json"
               "${CMAKE_CURRENT_BINARY_DIR}/plugInfo.json" @ONLY)

# --- install into the compiled-in plugin root (sibling of hdStorm) --------------------
# The base root plugInfo.json already Includes "*/resources/", so no root file
# is installed here.
install(TARGETS hdEmbree
  LIBRARY DESTINATION plugin/usd)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/plugInfo.json"
  DESTINATION plugin/usd/hdEmbree/resources)