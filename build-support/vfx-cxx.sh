#!/usr/bin/env bash
# Shared host C++ settings. Source this from a delegate builder using pipefail.
_vfx_support_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

vfx_finish() {
    local rc="$1"
    if [ "$rc" -ne 0 ] && ! grep -q '^outcome=failed ' "$VFX_EVIDENCE_DIR/outcome.txt"; then
        printf 'outcome=failed phase=preparation exit_status=%s\n' "$rc" | tee "$VFX_EVIDENCE_DIR/outcome.txt"
    fi
}

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

# Log before execution: failed Docker RUN layers are not available as artifacts.
vfx_run() {
    local phase="$1" rc
    shift
    printf 'phase=%s command=' "$phase" | tee -a "$VFX_EVIDENCE_DIR/phases.log"
    printf '%q ' "$@" | tee -a "$VFX_EVIDENCE_DIR/phases.log"
    printf '\n' | tee -a "$VFX_EVIDENCE_DIR/phases.log"
    if "$@" 2>&1 | tee "$VFX_EVIDENCE_DIR/$phase.log"; then
        rc=0
    else
        local statuses=("${PIPESTATUS[@]}")
        rc="${statuses[0]}"
        if [ "$rc" -eq 0 ]; then rc="${statuses[1]}"; fi
    fi
    printf 'phase=%s exit_status=%s\n' "$phase" "$rc" | tee -a "$VFX_EVIDENCE_DIR/phases.log"
    if [ "$rc" -ne 0 ]; then
        printf 'outcome=failed phase=%s exit_status=%s\n' "$phase" "$rc" | tee "$VFX_EVIDENCE_DIR/outcome.txt"
    fi
    return "$rc"
}

vfx_cxx_init() {
    local delegate="$1" enable
    VFX_EVIDENCE_DIR="${VFX_EVIDENCE_DIR:-/usr/local/share/usd-render-benchmark/build-evidence/$delegate}"
    mkdir -p "$VFX_EVIDENCE_DIR"
    printf 'outcome=incomplete\n' > "$VFX_EVIDENCE_DIR/outcome.txt"
    trap 'vfx_finish "$?"' EXIT
    if ! vfx_select_year; then
        echo 'outcome=failed phase=year diagnostic=invalid-or-missing-year' | tee "$VFX_EVIDENCE_DIR/outcome.txt"
        return 1
    fi
    printf 'delegate=%s year=%s cxx_standard=%s base=%s\n' \
        "$delegate" "$VFX_PLATFORM_YEAR" "$VFX_CXX_STANDARD" "${VFX_BASE_IMAGE:-not-recorded}" \
        | tee "$VFX_EVIDENCE_DIR/requested-settings.txt"
    if [ "$delegate" = moonray ]; then
        vfx_run toolset-request vfx_check_requested_toolset "${MOONRAY_TOOLSET:-}" || return
    fi
    enable="${VFX_TOOLSET_ROOT:-/opt/rh}/gcc-toolset-${VFX_GCC_TOOLSET}/enable"
    if [ ! -r "$enable" ]; then
        printf 'outcome=failed phase=toolset diagnostic=missing:%s\n' "$enable" | tee "$VFX_EVIDENCE_DIR/outcome.txt"
        return 1
    fi
    # Software Collections enable scripts may reference unset variables.
    set +u
    if source "$enable"; then
        set -u
    else
        set -u
        echo 'outcome=failed phase=toolset diagnostic=activation-failed' | tee "$VFX_EVIDENCE_DIR/outcome.txt"
        return 1
    fi
    CC="$(command -v gcc)" || return
    CXX="$(command -v g++)" || return
    export CC CXX
    vfx_run compiler python3 "$_vfx_support_dir/vfx_cxx.py" compiler \
        --compiler "$CXX" --release "$VFX_GCC_RELEASE" \
        --output "$VFX_EVIDENCE_DIR/compiler.json" || return
    VFX_CMAKE_ARGS=(
        "-DCMAKE_C_COMPILER=$CC" "-DCMAKE_CXX_COMPILER=$CXX"
        "-DCMAKE_CXX_STANDARD=$VFX_CXX_STANDARD"
        -DCMAKE_CXX_STANDARD_REQUIRED=ON -DCMAKE_CXX_EXTENSIONS=OFF
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    )
}

vfx_record_source() {
    local source_dir="$1"
    vfx_run source git -C "$source_dir" rev-parse HEAD || return
    vfx_run submodules git -C "$source_dir" submodule status --recursive
}

vfx_save_config() {
    local build_dir="$1"
    if [ -f "$build_dir/CMakeCache.txt" ]; then
        cp "$build_dir/CMakeCache.txt" "$VFX_EVIDENCE_DIR/"
        grep -E '^CMAKE_(CXX_COMPILER|CXX_STANDARD|CXX_EXTENSIONS|CUDA_HOST_COMPILER|CUDA_FLAGS)[^=]*=' \
            "$build_dir/CMakeCache.txt" || true
    fi
    if [ -f "$build_dir/compile_commands.json" ]; then
        cp "$build_dir/compile_commands.json" "$VFX_EVIDENCE_DIR/"
    fi
}

vfx_configure() {
    local build_dir="$1" rc
    shift
    if vfx_run configure "$@"; then rc=0; else rc="$?"; fi
    # Preserve partial configure evidence before a builder's EXIT cleanup.
    vfx_save_config "$build_dir"
    return "$rc"
}

vfx_verify_commands() {
    local build_dir="$1"
    vfx_run settings python3 "$_vfx_support_dir/vfx_cxx.py" verify \
        --database "$build_dir/compile_commands.json" --compiler "$CXX" \
        --standard "$VFX_CXX_STANDARD" --output "$VFX_EVIDENCE_DIR/effective-settings.json"
}

vfx_check_plugin() {
    vfx_run loading python3 "$_vfx_support_dir/vfx_cxx.py" load --type "$1"
}

vfx_complete() {
    printf 'outcome=passed scope=delegate-host-cxx-settings-and-loading\n' | tee "$VFX_EVIDENCE_DIR/outcome.txt"
}
