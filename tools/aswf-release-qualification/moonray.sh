#!/usr/bin/env bash
# Configure unchanged OpenMoonRay in the released CY2025 image.
set -euo pipefail
src=${1:?read-only OpenMoonRay source tree}
out=${2:?fresh output directory}
test -f "$src/CMakeLists.txt"
test ! -e "$out"
mkdir -p "$out"
out=$(cd "$out" && pwd)
if [ -e /opt/conan_home ]; then
    test ! -e /tmp/aswf-release-conan-cache
    mv /opt/conan_home /tmp/aswf-release-conan-cache
fi
test ! -e /opt/conan_home
export OPTIX_ROOT=/usr/local/NVIDIA-OptiX-SDK-7.6.0
if timeout 300 cmake -S "$src" -B "$out/build" \
    -DCMAKE_INSTALL_PREFIX="$out/install" \
    -DCMAKE_PREFIX_PATH=/usr/local \
    -DCUDAToolkit_ROOT=/usr/local/cuda \
    -DBOOST_PYTHON_COMPONENT_NAME="python${ASWF_PYTHON_MAJOR_MINOR_VERSION//./}" \
    -DBUILD_QT_APPS=NO > "$out/configure.log" 2>&1; then
    status=0
else
    status=$?
fi
cat "$out/configure.log"
printf 'configure=%s\n' "$status" > "$out/status.txt"
exit "$status"
