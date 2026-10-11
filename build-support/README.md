# Optional annual host C++ build settings

Select `CXX_CONFORMANCE=off` (default) or CY2023–CY2027. Enabled mode requires a Cycles source build. CY2023–2025 select installed GCC11.2.x and request C++17; CY2026–2027 select GCC14.2.x and request C++20. A compiler probe verifies GCC identity/version and its default new libstdc++ ABI before the build. Missing or incompatible compiler environments fail without replacing SDK components.

`vfx-cxx.sh` activates the compiler and uses `vfx_cxx.py` for the probe. The Cycles script adds only conditional CMAKE_CXX_STANDARD and CMAKE_CXX_STANDARD_REQUIRED arguments, then builds and installs normally. The Docker caller removes its build directory after success; standalone callers manage cleanup. Off does not probe and preserves existing compiler, CUDA and CMake choices.

A successful enabled build means the delegate built with the selected compiler and requested CMake standard. No compilation database is generated or inspected. Target-specific standard or ABI overrides are not verified. This does not establish inherited-component, CUDA, runnable-image or runtime/render conformance.
