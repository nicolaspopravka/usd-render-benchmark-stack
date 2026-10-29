#!/usr/bin/env bash
# Run inside a disposable released ASWF container; never repair installed exports.
set -euo pipefail
out=${1:?output directory}
mkdir -p "$out"
out=$(cd "$out" && pwd)
probe=$(cd "$(dirname "$0")" && pwd)
test ! -e "$out/status.txt" || { echo 'Use a fresh output directory' >&2; exit 2; }
stage() {
    local name=$1 status
    shift
    printf 'COMMAND:'; printf ' %q' "$@"; printf '\n'
    if "$@" >"$out/$name.log" 2>&1; then status=0; else status=$?; fi
    if [ "$name" != exports ]; then cat "$out/$name.log"; fi
    printf '%s=%s\n' "$name" "$status" | tee -a "$out/status.txt"
    return "$status"
}
stage environment bash -c 'uname -a; cat /etc/os-release; env | sort | grep -E "^(ASWF_|PATH=|LD_LIBRARY_PATH=|PYTHONPATH=)"; cmake --version'
# A cache must be absent, rather than merely omitted from CMAKE_PREFIX_PATH.
if [ -e /opt/conan_home ]; then
    test ! -e /tmp/aswf-release-conan-cache
    mv /opt/conan_home /tmp/aswf-release-conan-cache
fi
test ! -e /opt/conan_home
stage exports bash -c 'find /usr/local -type f \( -name "pxrConfig.cmake" -o -name "pxrTargets*.cmake" \) -print -exec cat {} \;'
stage configure timeout 180 cmake -S "$probe/consumer" -B "$out/build" -DCMAKE_PREFIX_PATH=/usr/local
stage build timeout 180 cmake --build "$out/build" --verbose -j2
stage run timeout 30 "$out/build/consumer"
grep -qx CONSUMER_PASS "$out/run.log"
