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
# stdosl.h is self-contained - it has no #include of its own - so installing
# that single file from the matching OSL source release is enough. It lives at
# src/shaders/stdosl.h in the source tree, and FindOSL looks for it under
# ${prefix}/share/OSL/shaders (PATH_SUFFIXES "share/OSL/shaders", default
# prefixes include /usr/local).
#
# Validated against OSL 1.14.11.0:
#   OSL-1.14.11.0.tar.gz
#   sha256 3155fc5c3ad4a2026dd23fb9e7b77e936ac299f4bf1e7b332971471ca21ab714
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

if [ -s "${TARGET}" ]; then
    echo "OSL shader includes OK: ${TARGET} ($(wc -c < "${TARGET}") bytes)"
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
for tag in "${tags[@]}"; do
    # The release tag carries a leading v; the asset name does not.
    url="https://github.com/AcademySoftwareFoundation/OpenShadingLanguage/releases/download/${tag}/OSL-${tag#v}.tar.gz"
    echo "trying ${url}"
    if curl --location --fail --silent --show-error --max-time 600 -o "${TMPDIR:-/tmp}/osl-shaders.tar.gz" "${url}"; then
        member="$(tar -tzf "${TMPDIR:-/tmp}/osl-shaders.tar.gz" 2>/dev/null | grep -E '/src/shaders/stdosl\.h$' | head -1 || true)"
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
tar -xzf "${TMPDIR:-/tmp}/osl-shaders.tar.gz" -C "${TARGET_DIR}" --strip-components=3 "${src}"
rm -f "${TMPDIR:-/tmp}/osl-shaders.tar.gz"

if [ ! -s "${TARGET}" ]; then
    echo "ERROR: extracted ${src} but ${TARGET} is missing or empty." >&2
    exit 1
fi

echo "installed stdosl.h from OSL ${used_tag} (for the installed ${osl_version}):"
echo "  ${TARGET} ($(wc -c < "${TARGET}") bytes)"
