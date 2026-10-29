#!/usr/bin/env bash
# Independent stock/pristine/runnable checks; stock findings do not block builds.
set -uo pipefail
mode=${1:?stock, pristine or runnable}
year=${2:?year}
out=${3:?output directory}
probe=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
test ! -e "$out/status.txt" || exit 2
failed=0
stage() {
    local name=$1 status
    shift
    printf 'COMMAND:'; printf ' %q' "$@"; printf '\n'
    if "$@" > "$out/$name.log" 2>&1; then status=0; else status=$?; fi
    cat "$out/$name.log"
    printf '%s=%s\n' "$name" "$status" | tee -a "$out/status.txt"
    return "$status"
}
stage environment bash -c 'env | sort | grep -E "^(ASWF_|PATH=|PYTHONPATH=|LD_LIBRARY_PATH=|PXR_|HD_)"; cmake --version' || exit 2
if [ "$mode" = stock ]; then
    stage rez timeout 30 rez --version || true
    stage git-lfs timeout 30 git lfs version || true
    stage epoxy timeout 30 pkg-config --modversion epoxy || true
    stage python timeout 60 python3 -c 'from pxr import Usd; print(Usd.GetVersion()); print(Usd.Stage.CreateInMemory())' || true
elif [ "$mode" = pristine ]; then
    rez=rez
    if [ -x /opt/rez/bin/rez/rez ]; then rez=/opt/rez/bin/rez/rez; fi
    stage rez timeout 30 "$rez" --version || failed=1
elif [ "$mode" = runnable ]; then
    stage rez timeout 30 rez --version || failed=1
    stage python timeout 60 python3 -c 'from pxr import Usd; print(Usd.GetVersion()); print(Usd.Stage.CreateInMemory())' || failed=1
    stage rez-resolve timeout 60 env REZ_PACKAGES_PATH="$probe/packages" rez env usd -- python3 -c 'from pxr import Usd; print(Usd.Stage.CreateInMemory())' || failed=1
    stage plugins timeout 60 python3 -c 'from pxr import UsdImagingGL, UsdAppUtils; print(UsdImagingGL.Engine.GetRendererPlugins()); print([(n, UsdAppUtils.rendererArgs.GetPluginIdFromArgument(n)) for n in ("GL", "Storm")])' || failed=1
    if [ "$year" -le 2025 ]; then
        stage cycles-load timeout 60 python3 -c 'import ctypes; ctypes.CDLL("/opt/cycles/hydra/hdCycles.so"); print("CYCLES_LOAD_PASS")' || failed=1
        stage moonray-load timeout 60 python3 -c 'import ctypes; ctypes.CDLL("/usr/local/plugin/hd_moonray.so"); print("MOONRAY_LOAD_PASS")' || failed=1
    fi
else
    exit 2
fi
# Never let an existing Conan cache supply a deployed-package dependency.
if [ -e /opt/conan_home ]; then
    test ! -e /tmp/release-check-conan-cache || exit 2
    mv /opt/conan_home /tmp/release-check-conan-cache || exit 2
fi
test ! -e /opt/conan_home || exit 2
if stage consumer-configure timeout 180 cmake -S "$probe/consumer" -B "$out/build" -DCMAKE_PREFIX_PATH=/usr/local; then
    if stage consumer-build timeout 180 cmake --build "$out/build" --verbose -j2; then
        stage consumer-run timeout 30 "$out/build/consumer" || failed=1
    else
        failed=1
    fi
else
    failed=1
fi
# Missing integration tools in the stock dependency image are observations.
if [ "$mode" = stock ]; then exit 0; fi
exit "$failed"
