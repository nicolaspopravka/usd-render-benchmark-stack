#!/usr/bin/env bash
# Restore missing shader headers matching the installed OSL version.
set -euo pipefail

PREFIX="${ASWF_INSTALL_PREFIX:-/usr/local}"
TARGET_DIR="${PREFIX}/share/OSL/shaders"
TARGET="${TARGET_DIR}/stdosl.h"
OSL_SHADER_TAG_OVERRIDE="${OSL_SHADER_TAG_OVERRIDE:-}"

if [ -s "${TARGET}" ] && [ -s "${TARGET_DIR}/vector2.h" ]; then
    exit 0
fi

if ! command -v oslc >/dev/null 2>&1; then
    echo "ERROR: no oslc, so the installed OSL cannot be identified or used." >&2
    exit 1
fi

# Read headers rather than invoking oslc, whose LLVM runtime may be missing.
version_header="${PREFIX}/include/OSL/oslversion.h"
if [ ! -r "${version_header}" ]; then
    echo "ERROR: ${version_header} is missing; installed OSL version is unknown." >&2
    exit 1
fi
read -r osl_major osl_minor osl_patch <<EOF
$(sed -nE 's/^[[:space:]]*#define[[:space:]]+OSL_LIBRARY_VERSION_(MAJOR|MINOR|PATCH)[[:space:]]+([0-9]+).*/\2/p' "${version_header}" | tr '\n' ' ')
EOF
osl_version="${osl_major}.${osl_minor}.${osl_patch}"
case "${osl_version}" in
    *..*|.*|*.) echo "ERROR: could not parse the OSL version from ${version_header}" >&2; exit 1 ;;
esac

# OSL release tags commonly append .0 to the header version.
if [ -n "${OSL_SHADER_TAG_OVERRIDE}" ]; then
    tags=("${OSL_SHADER_TAG_OVERRIDE}")
else
    tags=("v${osl_version}.0" "v${osl_version}")
fi

src=""
used_tag=""
for tag in "${tags[@]}"; do
    url="https://github.com/AcademySoftwareFoundation/OpenShadingLanguage/archive/refs/tags/${tag}.tar.gz"
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
    exit 1
fi

mkdir -p "${TARGET_DIR}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
tar -xzf "${TMPDIR:-/tmp}/osl-shaders.tar.gz" -C "${work}" --strip-components=1 \
    "OpenShadingLanguage-${used_tag#v}/src/shaders"
install -m 0644 "${work}"/src/shaders/*.h "${TARGET_DIR}/"
rm -f "${TMPDIR:-/tmp}/osl-shaders.tar.gz"

if [ ! -s "${TARGET}" ]; then
    echo "ERROR: extracted ${used_tag} but ${TARGET} is missing or empty." >&2
    exit 1
fi
