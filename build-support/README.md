# Optional annual C++ build settings

The helper is shared with main: CY2023–2025 select gcc-toolset-11/C++17; CY2026–2027 select gcc-toolset-14/C++20. Enabled callers source the selected toolset and export only VFX_CXX_STANDARD. Renderer scripts request CMAKE_CXX_STANDARD and CMAKE_CXX_STANDARD_REQUIRED, then build/install normally. Off preserves the established renderer compiler and CMake defaults.

Cleanup is in Docker after successful build/install. Standalone callers manage cleanup. No compiler/ABI probes or compilation-command checks are performed; this selects settings, not image-wide or runtime conformance.
