#!/usr/bin/env bash
# Optional image-side profile; delegate scripts contain only Git/CMake commands.
_vfx_support_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

vfx_select_year() {
    case "${CXX_CONFORMANCE:-off}" in
        off) unset VFX_CXX_STANDARD VFX_GCC_TOOLSET VFX_GCC_RELEASE; return 0 ;;
        2023|2024|2025) VFX_CXX_STANDARD=17; VFX_GCC_TOOLSET=11; VFX_GCC_RELEASE=11.2 ;;
        2026|2027) VFX_CXX_STANDARD=20; VFX_GCC_TOOLSET=14; VFX_GCC_RELEASE=14.2 ;;
        *) echo 'ERROR: CXX_CONFORMANCE must be off or 2023–2027' >&2; return 1 ;;
    esac
}

vfx_check_requested_toolset() {
    [ "${CXX_CONFORMANCE:-off}" != off ] || return 0
    if [ -n "$1" ] && [ "$1" != "gcc-toolset-${VFX_GCC_TOOLSET}" ]; then
        printf 'ERROR: requested toolset %s conflicts with CY%s host toolset gcc-toolset-%s\n' \
            "$1" "$CXX_CONFORMANCE" "$VFX_GCC_TOOLSET" >&2
        return 1
    fi
}

vfx_cxx_environment() {
    vfx_select_year || return
    [ "${CXX_CONFORMANCE:-off}" != off ] || return 0
    vfx_check_requested_toolset "${1:-}" || return
    local enable="${VFX_TOOLSET_ROOT:-/opt/rh}/gcc-toolset-${VFX_GCC_TOOLSET}/enable"
    if [ ! -r "$enable" ]; then
        printf 'ERROR: missing annual compiler environment: %s\n' "$enable" >&2
        return 1
    fi
    # Software Collections scripts may reference unset variables.
    local rc=0 nounset="${-//[^u]/}"
    set +u
    source "$enable" || rc="$?"
    if [ -n "$nounset" ]; then set -u; fi
    if [ "$rc" -ne 0 ]; then return "$rc"; fi
    CC="$(command -v gcc)" || return
    CXX="$(command -v g++)" || return
    export CC CXX VFX_CXX_STANDARD
    python3 "$_vfx_support_dir/vfx_cxx.py" compiler --compiler "$CXX" --release "$VFX_GCC_RELEASE"
}

vfx_cxx_check() {
    [ "${CXX_CONFORMANCE:-off}" != off ] || return 0
    python3 "$_vfx_support_dir/vfx_cxx.py" profile \
        --database "$1/compile_commands.json" --compiler "$CXX" \
        --release "$VFX_GCC_RELEASE" --standard "$VFX_CXX_STANDARD"
}
