#!/usr/bin/env bash
# External acceptance checks around an otherwise ordinary delegate build.
set -euo pipefail
support_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$support_dir/vfx-cxx.sh"
vfx_select_year

delegate="$1"
source_dir="$2"
build_dir="$3"
plugin_type="$4"
shift 4
: "${CXX:?Select the annual compiler in the image environment first}"
VFX_EVIDENCE_DIR="${VFX_EVIDENCE_DIR:-/usr/local/share/usd-render-benchmark/build-evidence/$delegate}"
mkdir -p "$VFX_EVIDENCE_DIR"
printf 'outcome=incomplete\n' > "$VFX_EVIDENCE_DIR/outcome.txt"
printf 'delegate=%s year=%s cxx_standard=%s base=%s\n' \
    "$delegate" "$VFX_PLATFORM_YEAR" "$VFX_CXX_STANDARD" "${VFX_BASE_IMAGE:-not-recorded}" \
    | tee "$VFX_EVIDENCE_DIR/requested-settings.txt"

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

save_evidence() {
    local rc="$?"
    trap - EXIT
    set +e
    evidence_failed() { if [ "$rc" -eq 0 ]; then rc=1; fi; }
    if [ -e "$source_dir/.git" ]; then
        git -C "$source_dir" rev-parse HEAD | tee "$VFX_EVIDENCE_DIR/source.txt" || evidence_failed
        git -C "$source_dir" submodule status --recursive | tee "$VFX_EVIDENCE_DIR/submodules.txt" || evidence_failed
    fi
    if [ -f "$build_dir/CMakeCache.txt" ]; then
        cp "$build_dir/CMakeCache.txt" "$VFX_EVIDENCE_DIR/" || evidence_failed
        grep -E '^CMAKE_(CXX_COMPILER|CXX_STANDARD|CXX_EXTENSIONS|CUDA_HOST_COMPILER|CUDA_FLAGS)[^=]*=' \
            "$build_dir/CMakeCache.txt" || true
    fi
    if [ -f "$build_dir/compile_commands.json" ]; then
        cp "$build_dir/compile_commands.json" "$VFX_EVIDENCE_DIR/" || evidence_failed
        # On a build failure, report settings too, without changing its status.
        if [ "$rc" -ne 0 ]; then
            python3 "$support_dir/vfx_cxx.py" verify \
                --database "$build_dir/compile_commands.json" --compiler "$CXX" \
                --standard "$VFX_CXX_STANDARD" --output "$VFX_EVIDENCE_DIR/effective-settings.json"
        fi
    fi
    if [ "$rc" -ne 0 ] && ! grep -q '^outcome=failed ' "$VFX_EVIDENCE_DIR/outcome.txt"; then
        printf 'outcome=failed phase=validation exit_status=%s\n' "$rc" | tee "$VFX_EVIDENCE_DIR/outcome.txt"
    fi
    if [ "$rc" -eq 0 ]; then
        printf 'outcome=passed scope=delegate-host-cxx-settings-and-loading\n' | tee "$VFX_EVIDENCE_DIR/outcome.txt" || rc=1
    fi
    exit "$rc"
}
trap save_evidence EXIT
vfx_run compiler python3 "$support_dir/vfx_cxx.py" compiler \
    --compiler "$CXX" --release "$VFX_GCC_RELEASE" --output "$VFX_EVIDENCE_DIR/compiler.json"
vfx_run build "$@"
vfx_run settings python3 "$support_dir/vfx_cxx.py" verify \
    --database "$build_dir/compile_commands.json" --compiler "$CXX" \
    --standard "$VFX_CXX_STANDARD" --output "$VFX_EVIDENCE_DIR/effective-settings.json"
vfx_run loading python3 "$support_dir/vfx_cxx.py" load --type "$plugin_type"
