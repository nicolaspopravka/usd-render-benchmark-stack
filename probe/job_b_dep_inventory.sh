#!/usr/bin/env bash
# Job B — does MoonRay build directly on the published stack:2026.3 base?
# (ExecPlan Phase 2, Job B — the base-lineage decision's evidence.)
#
# The ExecPlan chose lineage "onto the published stack:2026.3" probe-gated:
# that image is ci-vfxall-based, so it lacks the MoonRay-only conan packages
# ci-moonray ships. This job
#   1. inventories /usr/local in both images and records the diff,
#   2. prints a dependency presence matrix for stack:2026.3,
#   3. provisions exactly the missing packages by copying their deployed
#      files out of ci-moonray:2026.6 (same conan packages, same profile —
#      no conan/network at provision time, byte-identical to the base that
#      Phase 42 proved buildable),
#   4. runs fixers 01/02/03, then the full build_moonray.sh on stack:2026.3,
#   5. verifies the install.
#
# A green run means Phase 3 can write the provisioning as COPY --from lines
# pinned to ci-moonray's digest. A red run classifies the fallback (chain
# route) from its log.
#
# Runs on a free GHA runner. Publishes nothing; logs + inventories are the
# artifacts.
set -euo pipefail
cd "$(dirname "$0")/.."

STACK_IMAGE="ghcr.io/nicolaspopravka/usd-render-benchmark-stack:2026.3"
MOON_IMAGE="aswf/ci-moonray:2026.6@sha256:57acaa6ae00e83a9862ae7b0ba1a2cea53dc6855a86d43a7ead9795266d3a7e7"
MOONRAY_REPO_URL="https://github.com/nicolaspopravka/openmoonray.git"
MOONRAY_TAG="usd26-moonray"
# nvcc 12.9 cannot host-compile with gcc-toolset-14; the rocky8 base's
# system gcc 8.5 is inside the supported range (see host_compiler_probe).
CUDA_HOST_COMPILER="/usr/bin/g++"

mkdir -p probe/out
LOG="probe/out/job_b_dep_inventory.log"
exec > >(tee "${LOG}") 2>&1

# Source-tree globs per dependency, searched in ci-moonray (both the
# /usr/local conan deploy and any system paths). Expanded nullglob-safe
# inside the container; empty result = hard error, so a wrong guess is
# visible instead of silently skipped.
patterns_for() {
    case "$1" in
    jsoncpp)          echo '/usr/local/include/jsoncpp /usr/local/include/json/json.h /usr/local/lib*/libjsoncpp* /usr/local/lib*/cmake/jsoncpp /usr/local/lib*/pkgconfig/jsoncpp.pc /usr/include/jsoncpp /usr/lib64/libjsoncpp*' ;;
    glfw)             echo '/usr/local/include/GLFW /usr/local/lib*/libglfw* /usr/local/lib*/cmake/glfw3* /usr/local/lib*/pkgconfig/glfw3.pc /usr/include/GLFW /usr/lib64/libglfw*' ;;
    lua)              echo '/usr/local/include/lua.h /usr/local/include/luaconf.h /usr/local/include/lua*/lua.h /usr/local/include/lua5.4 /usr/local/lib*/liblua* /usr/local/lib*/pkgconfig/lua*.pc /usr/local/lib*/cmake/lua* /usr/include/lua.h /usr/lib64/liblua*' ;;
    libmicrohttpd)    echo '/usr/local/include/microhttpd.h /usr/local/lib*/libmicrohttpd* /usr/local/lib*/pkgconfig/libmicrohttpd.pc /usr/include/microhttpd.h /usr/lib64/libmicrohttpd*' ;;
    libcgroup)        echo '/usr/local/include/libcgroup* /usr/local/lib*/libcgroup* /usr/local/lib*/pkgconfig/libcgroup* /usr/include/libcgroup* /usr/lib64/libcgroup*' ;;
    random123)        echo '/usr/local/include/Random123* /usr/local/include/random123* /usr/include/Random123* /usr/include/random123*' ;;
    openimagedenoise) echo '/usr/local/include/OpenImageDenoise /usr/local/lib*/libOpenImageDenoise* /usr/local/lib*/cmake/OpenImageDenoise* /usr/local/lib*/pkgconfig/OpenImageDenoise.pc /usr/include/OpenImageDenoise /usr/lib64/libOpenImageDenoise*' ;;
    freetype)         echo '/usr/local/include/freetype2 /usr/local/include/ft2build.h /usr/local/lib*/libfreetype* /usr/local/lib*/cmake/freetype* /usr/local/lib*/pkgconfig/freetype*.pc /usr/include/freetype2 /usr/lib64/libfreetype*' ;;
    libjpeg)          echo '/usr/local/include/jpeglib.h /usr/local/include/jerror.h /usr/local/include/jconfig.h /usr/local/include/jmorecfg.h /usr/local/lib*/libjpeg* /usr/local/lib*/pkgconfig/libjpeg*.pc /usr/include/jpeglib.h /usr/lib64/libjpeg*' ;;
    embree)           echo '/usr/local/include/embree4 /usr/local/lib*/libembree4* /usr/local/lib*/cmake/embree* /usr/include/embree4 /usr/lib64/libembree4*' ;;
    log4cplus)        echo '/usr/local/include/log4cplus /usr/local/lib*/liblog4cplus* /usr/local/lib*/cmake/log4cplus* /usr/local/lib*/pkgconfig/liblog4cplus.pc /usr/include/log4cplus /usr/lib64/liblog4cplus*' ;;
    cppunit)          echo '/usr/local/include/cppunit /usr/local/lib*/libcppunit* /usr/local/lib*/pkgconfig/cppunit.pc /usr/include/cppunit /usr/lib64/libcppunit*' ;;
    openssl)          echo '/usr/local/include/openssl /usr/local/lib*/libssl* /usr/local/lib*/libcrypto* /usr/include/openssl /usr/lib64/libssl*' ;;
    zlib)             echo '/usr/local/include/zlib.h /usr/local/lib*/libz.* /usr/local/lib*/pkgconfig/zlib.pc /usr/include/zlib.h /usr/lib64/libz.*' ;;
    opengl)           echo '/usr/local/include/GL /usr/include/GL /usr/lib64/libGL.so*' ;;
    *)                echo '' ;;
    esac
}

echo "=== Job B: stack image ${STACK_IMAGE}"
echo "=== moonray dep source image ${MOON_IMAGE}"
docker pull "${STACK_IMAGE}"
docker pull "${MOON_IMAGE}"

echo "--- inventories"
docker run --rm "${MOON_IMAGE}" \
    bash -lc 'find /usr/local \( -type f -o -type l \) | LC_ALL=C sort' \
    > probe/out/usr_local.ci-moonray-2026.6.txt
docker run --rm "${STACK_IMAGE}" \
    bash -lc 'find /usr/local \( -type f -o -type l \) | LC_ALL=C sort' \
    > probe/out/usr_local.stack-2026.3.txt
comm -23 probe/out/usr_local.ci-moonray-2026.6.txt probe/out/usr_local.stack-2026.3.txt \
    > probe/out/only-in-ci-moonray.txt
wc -l probe/out/usr_local.*.txt probe/out/only-in-ci-moonray.txt

echo "--- presence matrix on ${STACK_IMAGE} (before provisioning)"
docker run --rm -v "${PWD}/probe:/probe:ro" "${STACK_IMAGE}" \
    bash /probe/presence_check.sh | tee probe/out/presence_stack_before.txt

MISSING="$(awk '/^MISSING/{print $2}' probe/out/presence_stack_before.txt || true)"
echo "missing: ${MISSING:-<none>}"

if [ -n "${MISSING}" ]; then
    echo "--- provisioning from ci-moonray:2026.6"
    mkdir -p probe/out/provision
    for name in ${MISSING}; do
        pats="$(patterns_for "${name}")"
        if [ -z "${pats}" ]; then
            echo "FAIL: no provisioning pattern for ${name}"
            exit 1
        fi
        echo ">>> ${name}"
        # Host only word-splits (read -ra): every glob is expanded inside the
        # container, where the paths actually exist. Non-existent literals
        # (an absent optional path) are filtered by the existence check
        # instead of reaching tar, which is what broke the first attempt.
        read -ra pat_arr <<< "${pats}"
        docker run --rm -i "${MOON_IMAGE}" bash -s -- "${pat_arr[@]}" <<'EOS' | tar -xf - -C probe/out/provision
set -euo pipefail
files=()
for pat in "$@"; do
    for f in ${pat}; do          # unquoted = container-side glob expansion
        if [ -e "${f}" ]; then
            files+=("${f}")
        fi
    done
done
if [ "${#files[@]}" -eq 0 ]; then
    echo "NO FILES for patterns: $*" >&2
    exit 3
fi
tar cf - "${files[@]}"
EOS
    done
    du -sh probe/out/provision || true
    find probe/out/provision -type f | wc -l
fi

echo "--- provision + fixers + build + verify, all inside ${STACK_IMAGE}"
# Two mounts: the repo root carries fixers/ and build_moonray.sh, probe/
# carries the probe scripts and the provisioned files.
docker run --rm -v "${PWD}:/repo" -v "${PWD}/probe:/probe" -w /repo "${STACK_IMAGE}" bash -lc '
set -euo pipefail

if [ -d /probe/out/provision/usr ]; then
    echo "--- copying provisioned files into /usr"
    cp -a /probe/out/provision/usr/. /usr/
    ldconfig
fi

echo "--- presence matrix after provisioning (STRICT)"
STRICT=1 bash /probe/presence_check.sh

echo "--- fixers"
bash /repo/fixers/01-gitlfs-prereqs.sh
bash /repo/fixers/02-openusd-cmake-exports.sh
bash /repo/fixers/03-ispc.sh

echo "--- build_moonray.sh"
BUILD_RC=0
MOONRAY_REPO_URL="'"${MOONRAY_REPO_URL}"'" \
MOONRAY_TAG="'"${MOONRAY_TAG}"'" \
CUDA_HOST_COMPILER="'"${CUDA_HOST_COMPILER}"'" \
    bash /repo/build_moonray.sh || BUILD_RC=$?

if [ "${BUILD_RC}" -eq 0 ]; then
    echo "--- verification"
    bash /probe/verify_moonray.sh
    echo "=== JOB B PASS"
else
    echo "--- diagnostics after failed build (BUILD_RC=${BUILD_RC})"
    echo "passed CUDA_HOST_COMPILER="'"${CUDA_HOST_COMPILER:-<unset>}"'
    grep -E "^CMAKE_CUDA" /opt/build-moonray/build/CMakeCache.txt 2>/dev/null || echo "(no CMakeCache)"
    grep -rho -m2 -- "--compiler-bindir=[^ \"]*\|-ccbin=[^ \"]*" /opt/build-moonray/build 2>/dev/null | sort -u | head -3 || echo "(no -ccbin in build tree)"
    exit "${BUILD_RC}"
fi
'

echo "=== Job B finished"
