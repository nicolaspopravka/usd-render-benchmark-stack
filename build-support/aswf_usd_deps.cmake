# Consumer support for incomplete ASWF OpenUSD dependency exports.
# Load package configs and resolve missing targets to deployed libraries.
include_guard(GLOBAL)

find_package(OpenGL REQUIRED)
# Resolve Threads early: propagated -pthread flags break older MoonRay ISPC targets.
find_package(Threads REQUIRED)

find_package(Imath CONFIG QUIET)
find_package(OpenImageIO CONFIG QUIET)
find_package(OpenEXR CONFIG QUIET)
find_package(OpenColorIO CONFIG QUIET)
find_package(TBB CONFIG QUIET)
find_package(OpenSubdiv CONFIG QUIET)

# Resolve OpenVDB before configs can introduce an empty target.
find_library(ASWF_USD_openvdb_LIBRARY NAMES openvdb PATHS /usr/local/lib)
if(ASWF_USD_openvdb_LIBRARY AND NOT TARGET OpenVDB::openvdb)
  add_library(OpenVDB::openvdb UNKNOWN IMPORTED)
  set_target_properties(OpenVDB::openvdb PROPERTIES
    IMPORTED_LOCATION "${ASWF_USD_openvdb_LIBRARY}")
  message(STATUS
    "aswf_usd_deps: OpenVDB::openvdb -> ${ASWF_USD_openvdb_LIBRARY}")
endif()
find_package(OpenVDB CONFIG QUIET)

macro(aswf_usd_define_imported target_name lib_name)
  if(NOT TARGET ${target_name})
    find_library(ASWF_USD_${lib_name}_LIBRARY NAMES ${lib_name} PATHS /usr/local/lib)
    if(NOT ASWF_USD_${lib_name}_LIBRARY)
      # Conan may omit unversioned shared-library symlinks.
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
        IMPORTED_LOCATION "${ASWF_USD_${lib_name}_LIBRARY}"
        INTERFACE_INCLUDE_DIRECTORIES "/usr/local/include")
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
aswf_usd_define_imported(TBB::tbb tbb)

# Older USD exports retain Conan target names.
aswf_usd_define_imported(
  CONAN_LIB::materialx_materialx_MaterialXCore_MaterialXCore_RELEASE MaterialXCore)
aswf_usd_define_imported(
  CONAN_LIB::materialx_materialx_MaterialXFormat_MaterialXFormat_RELEASE MaterialXFormat)
aswf_usd_define_imported(OpenSubdiv::osdCPU osdCPU)
aswf_usd_define_imported(OpenSubdiv::osdGPU osdGPU)
aswf_usd_define_imported(Ptex::Ptex_dynamic Ptex)
aswf_usd_define_imported(
  CONAN_LIB::ptex_Ptex_Ptex_dynamic_Ptex_RELEASE Ptex)
string(REPLACE "." "" _aswf_python "$ENV{ASWF_PYTHON_MAJOR_MINOR_VERSION}")
aswf_usd_define_imported(
  "CONAN_LIB::boost_Boost_python_boost_python${_aswf_python}_RELEASE"
  "boost_python${_aswf_python}")
unset(_aswf_python)

# Bare OpenEXR targets need Imath in their link interface.
if(TARGET OpenEXR::OpenEXR AND TARGET Imath::Imath)
  get_target_property(_aswf_exr_ilb OpenEXR::OpenEXR INTERFACE_LINK_LIBRARIES)
  if(NOT _aswf_exr_ilb)
    set_property(TARGET OpenEXR::OpenEXR APPEND PROPERTY
      INTERFACE_LINK_LIBRARIES Imath::Imath)
  endif()
  unset(_aswf_exr_ilb)
endif()
