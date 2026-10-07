# OpenUSD's exported garch target references OpenGL::GL. Ensure that imported
# target exists before OpenUSD's pxrTargets.cmake loads. This changes neither
# Cycles nor OpenUSD source.
find_package(OpenGL REQUIRED)

# When the USD package supplies the OpenEXR target, FindUSDPixar reuses it as a
# bare imported location with no link interface, so Imath never reaches the
# link line even though Cycles' OpenVDB image code references Imath symbols.
# The standalone `cycles` executable then fails to link ("DSO missing from
# command line"); hdCycles.so tolerates it only because shared libraries may
# leave symbols undefined. Locate Imath here and put it on every target's link
# line. If a base ships no Imath config or library, continue without it rather
# than fail the configure — such a stack linked without it before.
if(NOT TARGET Imath::Imath)
  find_package(Imath CONFIG QUIET)
endif()
if(NOT TARGET Imath::Imath)
  find_library(CYCLES_IMATH_LIBRARY NAMES Imath)
  if(CYCLES_IMATH_LIBRARY)
    add_library(Imath::Imath UNKNOWN IMPORTED)
    set_target_properties(Imath::Imath PROPERTIES
      IMPORTED_LOCATION "${CYCLES_IMATH_LIBRARY}")
  endif()
endif()
if(TARGET Imath::Imath)
  link_libraries(Imath::Imath)
endif()

# OpenColorIO, OpenEXR and OpenImageIO: the same missing-DSO failure as the
# Imath case above, reached by a different route. The deployed pxrTargets
# exports reference these names (e.g. OpenColorIO::OpenColorIO), and the base's
# export fixer fills every referenced-but-absent name with an empty INTERFACE
# IMPORTED target. FindUSDPixar's target-reuse branch then sees a target that
# already exists, keeps it untouched, and never contributes a location: the
# real DSO stays off the link line and `bin/cycles` fails on the first
# OpenColorIO symbol colorspace.cpp needs (observed on the CY2026 build;
# hdCycles.so compiles and links anyway, because shared libraries may leave
# symbols undefined — which is a latent runtime hazard, not a pass). Defining
# the real targets here, before pxrConfig loads, makes both the export fixer
# and the reuse branch see them and keep them. The conan deploy does not always
# ship unversioned .so symlinks, so a versioned soname is matched by glob when
# find_library comes up empty. As with Imath, a library that cannot be located
# anywhere is skipped rather than fatal — such a stack linked without it
# before.
#
# A macro, not a function: link_libraries() sets a directory property, so it
# must run in this directory's scope to reach every target Cycles creates
# afterwards.
macro(cycles_link_installed_library target_name lib_name)
  if(NOT TARGET ${target_name})
    find_library(CYCLES_${lib_name}_LIBRARY NAMES ${lib_name} PATHS /usr/local/lib)
    if(NOT CYCLES_${lib_name}_LIBRARY)
      # Two soname shapes occur: dotted (libOpenColorIO.so.2.5) and hyphenated
      # (libOpenEXR-3_4.so.15). Both patterns are needed, and neither matches
      # another dependency's file — note libOpenImageIO.so.* must not become
      # libOpenImageIO*.so.*, which would also pick up OpenImageIO_Util.
      file(GLOB _cycles_lib_glob
        "/usr/local/lib/lib${lib_name}.so.*"
        "/usr/local/lib/lib${lib_name}-*.so.*")
      if(_cycles_lib_glob)
        list(GET _cycles_lib_glob 0 CYCLES_${lib_name}_LIBRARY)
      endif()
      unset(_cycles_lib_glob)
    endif()
    if(CYCLES_${lib_name}_LIBRARY)
      add_library(${target_name} UNKNOWN IMPORTED)
      set_target_properties(${target_name} PROPERTIES
        IMPORTED_LOCATION "${CYCLES_${lib_name}_LIBRARY}")
    endif()
  endif()
  if(TARGET ${target_name})
    link_libraries(${target_name})
  endif()
endmacro()

cycles_link_installed_library(OpenColorIO::OpenColorIO OpenColorIO)
cycles_link_installed_library(OpenEXR::OpenEXR OpenEXR)
cycles_link_installed_library(OpenImageIO::OpenImageIO OpenImageIO)

# OpenImageIO's Util companion, which FindUSDPixar's own bare target links.
if(TARGET OpenImageIO::OpenImageIO)
  find_library(CYCLES_OpenImageIO_Util_LIBRARY NAMES OpenImageIO_Util PATHS /usr/local/lib)
  if(NOT CYCLES_OpenImageIO_Util_LIBRARY)
    file(GLOB _cycles_lib_glob "/usr/local/lib/libOpenImageIO_Util.so.*")
    if(_cycles_lib_glob)
      list(GET _cycles_lib_glob 0 CYCLES_OpenImageIO_Util_LIBRARY)
    endif()
    unset(_cycles_lib_glob)
  endif()
  if(CYCLES_OpenImageIO_Util_LIBRARY)
    set_property(TARGET OpenImageIO::OpenImageIO APPEND PROPERTY
      INTERFACE_LINK_LIBRARIES "${CYCLES_OpenImageIO_Util_LIBRARY}")
  endif()
endif()
