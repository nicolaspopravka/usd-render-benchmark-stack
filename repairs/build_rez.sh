#!/usr/bin/env bash
# Install the requested Rez release with install.py at its final prefix.
set -ex

REZ_VERSION="${ASWF_REZ_VERSION:?ASWF_REZ_VERSION must be set (per-year VFX Platform version)}"
REZ_INSTALL_DIR="${ASWF_INSTALL_PREFIX:-/usr/local}/rez"

if [[ ! -f "$DOWNLOADS_DIR/rez-${REZ_VERSION}.tar.gz" ]]; then
    curl --location --fail \
        "https://github.com/AcademySoftwareFoundation/rez/releases/download/${REZ_VERSION}/${REZ_VERSION}.tar.gz" \
        -o "$DOWNLOADS_DIR/rez-${REZ_VERSION}.tar.gz"
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

cp "$DOWNLOADS_DIR/rez-${REZ_VERSION}.tar.gz" "$workdir/rez.tar.gz"

mkdir "${workdir}/src"
tar xf "${workdir}/rez.tar.gz" -C "${workdir}/src" --strip-components 1

cd "${workdir}/src"
python3 ./install.py "${REZ_INSTALL_DIR}"

"${REZ_INSTALL_DIR}"/bin/rez/rez --version
