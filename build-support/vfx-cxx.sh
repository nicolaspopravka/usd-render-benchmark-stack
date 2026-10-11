#!/usr/bin/env bash
# Optional image-side profile; delegate scripts contain only Git/CMake commands.

vfx_select_year() {
    case "${CXX_CONFORMANCE:-off}" in
        off) unset VFX_CXX_STANDARD VFX_GCC_TOOLSET VFX_GCC_RELEASE; return 0 ;;
        2023|2024|2025) VFX_CXX_STANDARD=17; VFX_GCC_TOOLSET=11; VFX_GCC_RELEASE=11.2 ;;
        2026|2027) VFX_CXX_STANDARD=20; VFX_GCC_TOOLSET=14; VFX_GCC_RELEASE=14.2 ;;
        *) echo 'ERROR: CXX_CONFORMANCE must be off or 2023–2027' >&2; return 1 ;;
    esac
}

vfx_cxx_environment() {
    vfx_select_year || return
    [ "${CXX_CONFORMANCE:-off}" != off ] || return 0
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
    local version macros
    version="$("$CXX" -dumpfullversion)" || return
    case "$version" in
        "$VFX_GCC_RELEASE"|"$VFX_GCC_RELEASE".*) ;;
        *) printf 'ERROR: expected GCC %s.x, found %s\n' "$VFX_GCC_RELEASE" "$version" >&2; return 1 ;;
    esac
    macros="$("$CXX" -dM -E -x c++ - <<< '#include <string>')" || return
    if grep -q '^#define __clang__ ' <<< "$macros" || ! grep -q '^#define __GNUC__ ' <<< "$macros"; then
        echo 'ERROR: the annual host compiler must be GCC' >&2
        return 1
    fi
    if ! grep -q '^#define _GLIBCXX_USE_CXX11_ABI 1$' <<< "$macros"; then
        echo 'ERROR: expected the new libstdc++ ABI (_GLIBCXX_USE_CXX11_ABI=1)' >&2
        return 1
    fi
    printf 'GCC %s; default libstdc++ ABI=1; requested C++%s\n' "$version" "$VFX_CXX_STANDARD"
}
