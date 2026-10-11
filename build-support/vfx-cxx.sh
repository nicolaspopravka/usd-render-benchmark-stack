#!/usr/bin/env bash
# Optional image-side settings; delegate scripts retain Git/CMake commands.

vfx_select_year() {
    case "${CXX_CONFORMANCE:-off}" in
        off) unset VFX_CXX_STANDARD VFX_GCC_TOOLSET ;;
        2023|2024|2025) VFX_CXX_STANDARD=17; VFX_GCC_TOOLSET=11 ;;
        2026|2027) VFX_CXX_STANDARD=20; VFX_GCC_TOOLSET=14 ;;
        *) echo 'ERROR: CXX_CONFORMANCE must be off or 2023–2027' >&2; return 1 ;;
    esac
}

vfx_cxx_environment() {
    vfx_select_year || return
    [ "${CXX_CONFORMANCE:-off}" != off ] || return 0
    source /opt/rh/gcc-toolset-${VFX_GCC_TOOLSET}/enable &&
        export VFX_CXX_STANDARD
}
