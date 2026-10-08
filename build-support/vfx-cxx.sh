#!/usr/bin/env bash
# Image/workflow environment selection; never sourced by delegate build scripts.
vfx_select_year() {
    case "${VFX_PLATFORM_YEAR:-}" in
        2023|2024|2025) VFX_CXX_STANDARD=17; VFX_GCC_TOOLSET=11; VFX_GCC_RELEASE=11.2 ;;
        2026|2027) VFX_CXX_STANDARD=20; VFX_GCC_TOOLSET=14; VFX_GCC_RELEASE=14.2 ;;
        *) echo 'ERROR: VFX_PLATFORM_YEAR must be one of 2023, 2024, 2025, 2026, 2027' >&2; return 1 ;;
    esac
}

vfx_check_requested_toolset() {
    local requested="$1"
    if [ -n "$requested" ] && [ "$requested" != "gcc-toolset-${VFX_GCC_TOOLSET}" ]; then
        printf 'ERROR: requested toolset %s conflicts with CY%s host toolset gcc-toolset-%s\n' \
            "$requested" "$VFX_PLATFORM_YEAR" "$VFX_GCC_TOOLSET" >&2
        return 1
    fi
}

vfx_cxx_environment() {
    vfx_select_year || return
    vfx_check_requested_toolset "${1:-}" || return
    local enable="${VFX_TOOLSET_ROOT:-/opt/rh}/gcc-toolset-${VFX_GCC_TOOLSET}/enable"
    if [ ! -r "$enable" ]; then
        printf 'ERROR: missing annual compiler environment: %s\n' "$enable" >&2
        return 1
    fi
    # Software Collections scripts may reference unset variables.
    local rc=0
    set +u
    source "$enable" || rc="$?"
    set -u
    if [ "$rc" -ne 0 ]; then
        echo 'ERROR: annual compiler activation failed' >&2
        return "$rc"
    fi
    CC="$(command -v gcc)" || return
    CXX="$(command -v g++)" || return
    export CC CXX VFX_CXX_STANDARD VFX_GCC_TOOLSET VFX_GCC_RELEASE
}
