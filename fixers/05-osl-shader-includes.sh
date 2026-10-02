#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Install the OSL shader includes that Cycles' OSL shaders compile against.
#
# Root cause: the ASWF conan OSL package deploys the libraries (oslcomp,
# oslexec, oslnoise, oslquery), the headers under include/OSL, and the oslc
# compiler, but not share/OSL/shaders. Cycles' FindOSL.cmake does not require
# OSL_SHADER_DIR - it is only mark_as_advanced - so configure succeeds, and the
# build then fails while compiling Cycles' own shaders:
#
#   src/kernel/osl/shaders/stdcycles.h:11:10: fatal error: 'stdosl.h' file not found
#
# i.e. the failure surfaces as a compile error in a generated shader rather than
# as a configuration error, which is a poor way to learn that a dependency is
# incomplete. With stdosl.h present, WITH_CYCLES_OSL can stay at its upstream
# default of ON and build_cycles.sh does not need the OFF override.
#
# stdosl.h is the one Cycles hits first, but it is not the only header the
# shader library needs: Cycles' own OSL shaders include their siblings, e.g.
# node_hash.h pulls in vector2.h and vector4.h. src/shaders is what OSL installs
# to share/OSL/shaders, so the fix installs that directory's headers. stdosl.h
# is also what liboslcomp itself looks up at runtime, by OSL_SHADER_INSTALL_DIR
# and then by guessing /usr/local/share/OSL/shaders/stdosl.h, so this path is
# the one the shipped library already expects.
#
# Validated against OSL 1.14.11.0, 1.13.11.0 and 1.12.14.0.
#   v1.14.11.0 tag archive (not the separately published release asset)
#   observed sha256 3f528f1c131cebda0896ffefa714f7bc34dd7ee21675605cf1ec155eccb1da05
#
# DROP THIS when the ASWF OSL conan package deploys share/OSL/shaders.
set -euo pipefail

PREFIX="${ASWF_INSTALL_PREFIX:-/usr/local}"
TARGET_DIR="${PREFIX}/share/OSL/shaders"
TARGET="${TARGET_DIR}/stdosl.h"
# Release tag to use instead of the one derived from the installed OSL. The
# upstream tags carry a fourth component, so a 1.14.11 install maps to
# v1.14.11.0. Only set this if the derivation below is wrong for your base.
OSL_SHADER_TAG_OVERRIDE="${OSL_SHADER_TAG_OVERRIDE:-}"

if [ -s "${TARGET}" ] && [ -s "${TARGET_DIR}/vector2.h" ]; then
    echo "OSL shader library OK: ${TARGET_DIR} ($(cd "${TARGET_DIR}" && ls -1 ./*.h | wc -l | tr -d ' ') headers)"
    exit 0
fi

if ! command -v oslc >/dev/null 2>&1; then
    echo "ERROR: no oslc, so the installed OSL cannot be identified or used." >&2
    echo "       Set OSL_SHADER_TAG_OVERRIDE to the release tag to install." >&2
    exit 1
fi

# Read the version out of the installed oslversion.h, the same way Cycles'
# own FindOSL.cmake does, so this cannot disagree with the version Cycles will
# build against. pkg-config is not an option here: the aswf conan OSL recipe
# rmdirs lib/pkgconfig and only re-declares pkg_config_name in package_info(),
# which is conan-graph metadata, so no OSL.pc is deployed.
version_header="${PREFIX}/include/OSL/oslversion.h"
if [ ! -r "${version_header}" ]; then
    echo "ERROR: ${version_header} is missing, so the installed OSL version" >&2
    echo "       is unknown. Set OSL_SHADER_TAG_OVERRIDE to the release tag." >&2
    exit 1
fi
read -r osl_major osl_minor osl_patch <<EOF
$(sed -nE 's/^[[:space:]]*#define[[:space:]]+OSL_LIBRARY_VERSION_(MAJOR|MINOR|PATCH)[[:space:]]+([0-9]+).*/\2/p' "${version_header}" | tr '\n' ' ')
EOF
osl_version="${osl_major}.${osl_minor}.${osl_patch}"
case "${osl_version}" in
    *..*|.*|*.) echo "ERROR: could not parse the OSL version from ${version_header}" >&2; exit 1 ;;
esac

# 1.14.11 -> v1.14.11.0, and 1.14.5.1 -> v1.14.5.1. Try the zero-padded form
# first, then the literal, and fail loudly if neither exists rather than
# silently skipping.
if [ -n "${OSL_SHADER_TAG_OVERRIDE}" ]; then
    tags=("${OSL_SHADER_TAG_OVERRIDE}")
else
    tags=("v${osl_version}.0" "v${osl_version}")
fi

src=""
used_tag=""
# Fetch the source from the tag archive rather than a release asset. OSL
# 1.12.14.0 and 1.13.11.0 asset URLs fail even though the tags exist; 1.14.11.0
# does have a release asset. Generated tag archives provide a common source.
for tag in "${tags[@]}"; do
    url="https://github.com/AcademySoftwareFoundation/OpenShadingLanguage/archive/refs/tags/${tag}.tar.gz"
    echo "trying ${url}"
    if curl --location --fail --silent --show-error --max-time 900 \
         -o "${TMPDIR:-/tmp}/osl-shaders.tar.gz" "${url}"; then
        member="$(tar -tzf "${TMPDIR:-/tmp}/osl-shaders.tar.gz" 2>/dev/null \
                 | grep -E '/src/shaders/stdosl\.h$' | head -1 || true)"
        if [ -n "${member}" ]; then
            src="${member}"
            used_tag="${tag}"
            break
        fi
    fi
done

if [ -z "${src}" ]; then
    echo "ERROR: no OSL release among [${tags[*]}] contained src/shaders/stdosl.h." >&2
    echo "       Installed OSL is ${osl_version}. Set OSL_SHADER_TAG_OVERRIDE" >&2
    echo "       to the release tag whose shader include matches it." >&2
    exit 1
fi

mkdir -p "${TARGET_DIR}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
# The generated archive root is OpenShadingLanguage-<tag without leading v>.
tar -xzf "${TMPDIR:-/tmp}/osl-shaders.tar.gz" -C "${work}" --strip-components=1 \
    "OpenShadingLanguage-${used_tag#v}/src/shaders"
# The whole header set from src/shaders, not just stdosl.h. Cycles' own OSL
# shaders include their siblings: node_hash.h pulls in vector2.h and vector4.h
# alongside stdcycles.h, and FindOSL only puts OSL_SHADER_DIR on the include
# path, so they all have to be in one place. src/shaders is the shader library
# that OSL installs to share/OSL/shaders; its .osl example sources are not
# installed, because nothing here compiles them.
install -m 0644 "${work}"/src/shaders/*.h "${TARGET_DIR}/"
rm -f "${TMPDIR:-/tmp}/osl-shaders.tar.gz"

if [ ! -s "${TARGET}" ]; then
    echo "ERROR: extracted ${used_tag} but ${TARGET} is missing or empty." >&2
    exit 1
fi

installed="$(cd "${TARGET_DIR}" && ls -1 ./*.h | wc -l | tr -d ' ')"
echo "installed the OSL ${used_tag} shader library (for the installed ${osl_version}, via the tag archive):"
echo "  ${TARGET_DIR}/ (${installed} headers)"
ls -1 "${TARGET_DIR}" | sed 's/^/    /'
