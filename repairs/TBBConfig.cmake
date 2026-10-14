# Classic TBB is deployed without its client CMake config.
get_filename_component(_tbb_prefix "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
find_library(TBB_LIBRARY NAMES tbb PATHS "${_tbb_prefix}/lib" NO_DEFAULT_PATH REQUIRED)
if(NOT TARGET TBB::tbb)
  add_library(TBB::tbb SHARED IMPORTED)
  set_target_properties(TBB::tbb PROPERTIES
    IMPORTED_LOCATION "${TBB_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${_tbb_prefix}/include")
endif()
unset(_tbb_prefix)
