# Describe the deployed shared library and its public math/task dependencies.
include(CMakeFindDependencyMacro)
find_dependency(TBB CONFIG)
find_dependency(Imath CONFIG)
get_filename_component(_openvdb_prefix "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
find_library(OpenVDB_LIBRARY NAMES openvdb PATHS "${_openvdb_prefix}/lib" NO_DEFAULT_PATH REQUIRED)
if(NOT TARGET OpenVDB::openvdb)
  add_library(OpenVDB::openvdb SHARED IMPORTED)
  set_target_properties(OpenVDB::openvdb PROPERTIES
    IMPORTED_LOCATION "${OpenVDB_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${_openvdb_prefix}/include"
    INTERFACE_LINK_LIBRARIES "TBB::tbb;Imath::Imath")
endif()
unset(_openvdb_prefix)
