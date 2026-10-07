#!/usr/bin/env bash
# Host-compiler matrix for nvcc (ExecPlan Phase 2, Job A step 0).
#
# The CY2026 images ship gcc-toolset-14, which nvcc (CUDA 12.9) cannot use as
# a host compiler: it dies inside GCC 14's <type_traits> on
# __is_nothrow_new_constructible while compiling OptixGPUPrograms.cu. This
# enumerates every gcc the image offers and asks nvcc to compile a
# type_traits-using TU with each, so the recipe can pick a working
# -ccbin / CMAKE_CUDA_HOST_COMPILER instead of guessing.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${1:-aswf/ci-moonray:2026.6@sha256:57acaa6ae00e83a9862ae7b0ba1a2cea53dc6855a86d43a7ead9795266d3a7e7}"

mkdir -p probe/out
exec > >(tee probe/out/host_compiler_probe.log) 2>&1

echo "=== host-compiler probe on ${IMAGE}"
docker pull "${IMAGE}" >/dev/null

docker run --rm "${IMAGE}" bash -lc '
set -uo pipefail
echo "--- toolchains present"
ls -d /opt/rh/* 2>/dev/null || echo "(no /opt/rh)"
echo "--- gcc on PATH and on disk"
which -a gcc g++ cc c++ 2>/dev/null || true
for g in /usr/bin/gcc /usr/bin/g++ /opt/rh/gcc-toolset-*/root/usr/bin/gcc /opt/rh/gcc-toolset-*/root/usr/bin/g++; do
    [ -x "$g" ] && echo "$g -> $($g --version 2>/dev/null | head -1)"
done
NVCC="$(command -v nvcc || echo /usr/local/cuda/bin/nvcc)"
echo "--- nvcc: ${NVCC}"
"${NVCC}" --version | tail -2

cat > /tmp/hosttest.cu <<"CU"
#include <type_traits>
struct S { int a; double b; };
__global__ void kern(S* s) {
    volatile bool b = std::is_nothrow_constructible<S>::value;
    (void)b;
    (void)s;
}
CU

echo "--- nvcc host-compiler matrix (trivial type_traits TU)"
try() {
    local label="$1"; shift
    if "${NVCC}" "$@" -ptx -o /tmp/hosttest.ptx /tmp/hosttest.cu 2>/tmp/hosttest.err; then
        echo "OK    ${label}"
    else
        echo "FAIL  ${label}:"
        grep -m2 "error" /tmp/hosttest.err || tail -2 /tmp/hosttest.err
    fi
}
try "default (PATH)"
for g in /usr/bin/g++ /usr/bin/gcc /opt/rh/gcc-toolset-*/root/usr/bin/g++; do
    [ -x "$g" ] && try "-ccbin ${g}" -ccbin "${g}"
done
echo "=== host-compiler probe done"
'
