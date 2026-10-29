#!/usr/bin/env bash
# Run inside a disposable runnable container with /benchmark mounted read-only.
set -euo pipefail
scene=${1:?mounted Teapot scene}
out=${2:?fresh output directory}
test -f "$scene"
mkdir -p "$out"
out=$(cd "$out" && pwd)
test ! -e "$out/status.txt" || { echo 'Use a fresh output directory' >&2; exit 2; }
dnf install -y --disablerepo=cuda mesa-dri-drivers xorg-x11-server-Xvfb xorg-x11-xauth > "$out/prerequisites.log" 2>&1
test -f /usr/local/lib/dri/swrast_dri.so
{
    env | sort | grep -E '^(ASWF_|LD_LIBRARY_PATH=|PYTHONPATH=|HD_|MESA_|LIBGL_)' || true
    ldd /usr/local/lib/dri/swrast_dri.so
    rpm -q mesa-dri-drivers
} > "$out/environment.log"
failed=0
for renderer in GL Cycles; do
    image="$out/$renderer.jpg"
    test ! -e "$image"
    # Xvfb uses its normal environment. Only its child render client selects
    # ASWF's LLVM-matched driver. No distro LLVM prepend or preload.
    if timeout 300 xvfb-run -a rez env aswf -- env LIBGL_ALWAYS_SOFTWARE=1 \
        LIBGL_DRIVERS_PATH=/usr/local/lib/dri LD_DEBUG=libs \
        LD_DEBUG_OUTPUT="$out/$renderer-loader" \
        usdrecord --camera main_cam --renderer "$renderer" \
        --purposes render "$scene" "$image" > "$out/$renderer.log" 2>&1; then
        status=0
    else
        status=$?
    fi
    printf '%s=%s\n' "$renderer" "$status" | tee -a "$out/status.txt"
    if [ "$status" -ne 0 ] || [ ! -s "$image" ]; then failed=1; fi
done
find "$out" -maxdepth 1 -type f -name '*-loader.*' -exec gzip {} +
# Exit status and fresh images are necessary; inspect plugins, loader traces
# and image appearance separately before accepting either render.
exit "$failed"
