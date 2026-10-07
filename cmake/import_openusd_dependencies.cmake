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
