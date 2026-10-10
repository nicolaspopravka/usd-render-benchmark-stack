# Shared OpenUSD dependency resolution for the ASWF conan deploy.
#
# Replaces three overlapping mechanisms:
#   * fixers/02-openusd-cmake-exports.sh, which rewrote the deployed
#     /usr/local/pxrConfig.cmake to synthesize empty INTERFACE targets;
#   * fixers/04-openvdb-config.sh, which wrote a stub OpenVDBConfig.cmake;
#   * cmake/import_openusd_dependencies.cmake, the Cycles-only compensation
#     for the damage the first two caused downstream.
#
# Every delegate (Cycles, hdEmbree, MoonRay) reaches the same deployed pxr
# package and therefore has the same problem. Resolving it once, here, is what
# keeps the delegate recipes from disagreeing about it.
#
# HOW THIS WORKS. This file runs before the consumer calls find_package(pxr),
# because the deployed exports reference imported targets they never define.
# The rule is one sentence: prefer the real package config, and only fall back
# to a bare imported target when no config exists. Nothing is defined as an
# empty INTERFACE library while a real one is available.
#
# WHY NOT JUST EMPTY TARGETS. An empty INTERFACE target satisfies a configure
# and then fails at link time with "DSO missing from command line", or worse,
# links successfully and leaves the symbol undefined in a shared library. On
# the CY2026 build that is exactly how bin/cycles failed on the first
# OpenColorIO symbol. It also poisons everything built later in the same image:
# an empty target that exists is reused, so the next consumer inherits it.
#
# WHY NOT PRE-DEFINE FALLBACKS EAGERLY. A generated export set refuses to load
# when only some of its targets already exist. OpenImageIO's set is eight
# targets (OpenImageIO, OpenImageIO_Util and six tools), so defining "both"
# that a reader would guess at still trips the check. Loading the real config
# first avoids the question entirely.
#
# A macro, not a function: link_libraries() sets a directory property, so it
# must run in this directory's scope to reach the targets the consumer creates
# afterwards.

include_guard(GLOBAL)

# --------------------------------------------------------------------------
# 1. OpenGL.
#
# USD's exported garch target references OpenGL::GL and the conan deploy does
# not define it. This is a real dependency (Cycles' OpenGLDevice and hdEmbree
# both link it), not a metadata reference, so a real find is required.
# --------------------------------------------------------------------------
find_package(OpenGL REQUIRED)

# --------------------------------------------------------------------------
# 2. Real package configs for the libraries the deployed exports reference.
#
# QUIET throughout: a base that genuinely lacks one of these is a condition to
# carry, not to fail on here. Step 3 handles those by location.
# --------------------------------------------------------------------------
find_package(Imath CONFIG QUIET)
find_package(OpenImageIO CONFIG QUIET)
find_package(OpenEXR CONFIG QUIET)
find_package(OpenColorIO CONFIG QUIET)
find_package(OpenVDB CONFIG QUIET)
find_package(TBB CONFIG QUIET)

# --------------------------------------------------------------------------
# 3. Location fallbacks, only for what step 2 did not provide.
#
# FindUSDPixar reuses an existing target and sets USD_OVERRIDE_* rather than
# contributing its own location, so a target that exists without one silently
# drops its library off the link line. That is the failure Cycles PR #86
# addresses at the source; this is the same guarantee for consumers that do
# not use FindUSDPixar.
#
# Every macro invocation resolves the library BEFORE defining the target, and
# defines nothing at all when the library is absent, so a base missing a
# dependency fails later with a link error naming it rather than here.
# --------------------------------------------------------------------------
macro(aswf_usd_define_imported target_name lib_name)
  if(NOT TARGET ${target_name})
    find_library(ASWF_USD_${lib_name}_LIBRARY NAMES ${lib_name} PATHS /usr/local/lib)
    if(NOT ASWF_USD_${lib_name}_LIBRARY)
      # The conan deploy does not always ship unversioned .so symlinks. Both
      # soname shapes occur: dotted (libOpenEXR.so.3.4) and hyphenated
      # (libOpenEXR-3_4.so.33). Note libOpenImageIO.so.* must not match
      # libOpenImageIO*.so.*, which would also pick up OpenImageIO_Util.
      file(GLOB _aswf_usd_lib_glob
        "/usr/local/lib/lib${lib_name}.so.*"
        "/usr/local/lib/lib${lib_name}-*.so.*")
      if(_aswf_usd_lib_glob)
        list(GET _aswf_usd_lib_glob 0 ASWF_USD_${lib_name}_LIBRARY)
      endif()
      unset(_aswf_usd_lib_glob)
    endif()
    if(ASWF_USD_${lib_name}_LIBRARY)
      add_library(${target_name} UNKNOWN IMPORTED)
      set_target_properties(${target_name} PROPERTIES
        IMPORTED_LOCATION "${ASWF_USD_${lib_name}_LIBRARY}")
      message(STATUS "aswf_usd_deps: ${target_name} -> ${ASWF_USD_${lib_name}_LIBRARY}")
    else()
      message(STATUS "aswf_usd_deps: ${lib_name} not found; ${target_name} left undefined")
    endif()
  endif()
endmacro()

aswf_usd_define_imported(OpenColorIO::OpenColorIO OpenColorIO)
aswf_usd_define_imported(OpenEXR::OpenEXR OpenEXR)
aswf_usd_define_imported(OpenImageIO::OpenImageIO OpenImageIO)
aswf_usd_define_imported(OpenImageIO::OpenImageIO_Util OpenImageIO_Util)
aswf_usd_define_imported(Imath::Imath Imath)

# --------------------------------------------------------------------------
# 4. Imath on the link line.
#
# FindUSDPixar's OpenEXR target is a bare location with no link interface, so
# Imath never reaches the link line even though Cycles' OpenVDB image code
# references Imath symbols; bin/cycles then fails with "DSO missing from
# command line". Attaching Imath to the OpenEXR target fixes it at the target
# that causes it, which is narrower than a directory-wide link_libraries().
# --------------------------------------------------------------------------
if(TARGET OpenEXR::OpenEXR AND TARGET Imath::Imath)
  get_target_property(_aswf_exr_ilb OpenEXR::OpenEXR INTERFACE_LINK_LIBRARIES)
  if(NOT _aswf_exr_ilb)
    set_property(TARGET OpenEXR::OpenEXR APPEND PROPERTY
      INTERFACE_LINK_LIBRARIES Imath::Imath)
  endif()
  unset(_aswf_exr_ilb)
endif()