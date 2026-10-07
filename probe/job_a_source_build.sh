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

mkdir -p probe/out
LOG="probe/out/job_a_source_build.log"
exec > >(tee "${LOG}") 2>&1

echo "=== Job A: source build on ${IMAGE}"
echo "=== source: ${MOONRAY_REPO_URL} @ ${MOONRAY_TAG}"
docker pull "${IMAGE}"

docker run --rm -v "${PWD}:/probe" -w /probe "${IMAGE}" bash -lc '
set -euo pipefail
echo "--- fixers"
bash /probe/fixers/01-gitlfs-prereqs.sh
bash /probe/fixers/02-openusd-cmake-exports.sh
bash /probe/fixers/03-ispc.sh

echo "--- dependency presence (informational on this base)"
bash /probe/presence_check.sh || true

echo "--- build_moonray.sh"
MOONRAY_REPO_URL="'"${MOONRAY_REPO_URL}"'" \
MOONRAY_TAG="'"${MOONRAY_TAG}"'" \
    bash /probe/build_moonray.sh

echo "--- verification"
bash /probe/verify_moonray.sh
echo "=== JOB A PASS"
'

echo "=== Job A finished"
