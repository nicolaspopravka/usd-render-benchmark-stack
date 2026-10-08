#!/usr/bin/env bash
# Job A — CY2026 MoonRay source feasibility (ExecPlan Phase 2, Job A).
#
# Question: does the patched combined branch (usd26-moonray = v2026.29.1 +
# hdMoonray PR #15 + moonray_sdr_plugins PR #6) build against the USD 26.03
# in aswf/ci-moonray:2026.6? That base is where GH #48's failure happened
# (moonray_sdr_plugins including the removed Ndr headers), so a green build
# here is the gate for everything downstream.
#
# Runs on a free GHA runner. Publishes nothing; the log is the artifact.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="aswf/ci-moonray:2026.6@sha256:57acaa6ae00e83a9862ae7b0ba1a2cea53dc6855a86d43a7ead9795266d3a7e7"
MOONRAY_REPO_URL="https://github.com/nicolaspopravka/openmoonray.git"
MOONRAY_TAG="usd26-moonray"
# The image default (gcc-toolset-14) is twice wrong for MoonRay: nvcc 12.9
# cannot host-compile with GCC 14, and GCC 13+ dropped the transitive
# standard-library includes the sources rely on (68 files / 7 submodules at
# the pins). gcc-toolset-12 answers both; fixer 04 installs it.
MOONRAY_TOOLSET="gcc-toolset-12"
TOOLSET_BIN="/opt/rh/${MOONRAY_TOOLSET}/root/usr/bin"
CC="${TOOLSET_BIN}/gcc"
CXX="${TOOLSET_BIN}/g++"
CUDA_HOST_COMPILER="${TOOLSET_BIN}/g++"

mkdir -p probe/out
LOG="probe/out/job_a_source_build.log"
exec > >(tee "${LOG}") 2>&1

echo "=== Job A: source build on ${IMAGE}"
echo "=== source: ${MOONRAY_REPO_URL} @ ${MOONRAY_TAG}"
echo "=== compilers: CC=${CC} CXX=${CXX} CUDA_HOST_COMPILER=${CUDA_HOST_COMPILER} (MOONRAY_TOOLSET=${MOONRAY_TOOLSET})"
docker pull "${IMAGE}"

docker run --rm -v "${PWD}:/probe" -w /probe "${IMAGE}" bash -lc '
set -euo pipefail
# keep-going: one run must enumerate EVERY missing-include failure, not
# stop at the first (the sweep fixes them all in one pass after this)
export MAKEFLAGS=-k
echo "--- fixers"
bash /probe/fixers/01-gitlfs-prereqs.sh
bash /probe/fixers/02-openusd-cmake-exports.sh
bash /probe/fixers/03-ispc.sh
MOONRAY_TOOLSET="'"${MOONRAY_TOOLSET}"'" bash /probe/fixers/04-moonray-toolset.sh

echo "--- dependency presence (informational on this base)"
bash /probe/presence_check.sh || true

echo "--- build_moonray.sh"
BUILD_RC=0
CC="'"${CC}"'" \
CXX="'"${CXX}"'" \
MOONRAY_REPO_URL="'"${MOONRAY_REPO_URL}"'" \
MOONRAY_TAG="'"${MOONRAY_TAG}"'" \
CUDA_HOST_COMPILER="'"${CUDA_HOST_COMPILER}"'" \
    bash /probe/build_moonray.sh || BUILD_RC=$?

if [ "${BUILD_RC}" -eq 0 ]; then
    echo "--- verification"
    bash /probe/verify_moonray.sh
    echo "=== JOB A PASS"
else
    echo "--- diagnostics after failed build (BUILD_RC=${BUILD_RC})"
    grep -E "^CMAKE_CUDA" /opt/build-moonray/build/CMakeCache.txt 2>/dev/null || echo "(no CMakeCache)"
    grep -rho -m2 -- "--compiler-bindir=[^ \"]*\|-ccbin=[^ \"]*" /opt/build-moonray/build 2>/dev/null | sort -u | head -3 || echo "(no -ccbin in build tree)"
    exit "${BUILD_RC}"
fi
'

echo "=== Job A finished"
