# Optional annual C++ build settings

`vfx-cxx.sh` maps CY2023–2025 to gcc-toolset-11/C++17 and CY2026–2027 to gcc-toolset-14/C++20. Enabled mode sources that toolset and exports only VFX_CXX_STANDARD for the Cycles script's conditional CMAKE_CXX_STANDARD and CMAKE_CXX_STANDARD_REQUIRED options. Off sources gcc-toolset-${ASWF_DTS_VERSION} and retains CMake defaults.

The normal build/install determines success; the Docker caller cleans up afterward. There are no compiler or ABI probes, compilation databases or per-command checks. This selects settings rather than verifying image-wide conformance. Requests without CYCLES_TAG remain allowed; compiler setup runs regardless of whether Cycles is built. The sourced environment applies within this Docker RUN; it is not persisted for later containers. Standalone callers manage cleanup.
