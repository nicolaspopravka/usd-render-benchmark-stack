#!/usr/bin/env bash
# Install Rez from the official source release, pinned to a known-good version.
#
# The ASWF images and benchmark pods previously bootstrapped Rez with
# `pip install rez`, which logs the "Pip-based rez installation detected"
# warning and is not a supported production delivery. This helper performs the
# supported source install (`install.py`) from the GitHub release tarball,
# verifying integrity against a pinned SHA-256, and is idempotent: it skips the
# download+install when the target already holds the pinned version.
#
# Usage (run on the pod; source it so the PATH export persists):
#   source tools/install_rez.sh
#
# No shell options are set or modified, so it is safe to source into any
# caller (with or without `set -e`/`pipefail`). Every fallible step has an
# explicit guard and returns 1 on failure.
#
# Environment overrides:
#   REZ_VERSION          Rez version to install (default 3.4.0)
#   REZ_INSTALL_DIR      Install prefix (default /opt/rez)
#   REZ_TARBALL_SHA256   Pinned sha256 of the release tarball (default verified 3.4.0)
#   REZ_TARBALL_URL      Full tarball URL (default GitHub release asset)
#
# Installed layout (matching WS2/WS3 validation on ASWF images):
#   $REZ_INSTALL_DIR/bin/rez/rez       the rez CLI
#   $REZ_INSTALL_DIR/lib/python*/site-packages/rez   the rez API
# No builtin packages ship with the source install; the standard
# `rez env <pkg> -- <cmd>` render flow resolves fine, but `rez env ... bash -c`
# usages need minimal `bash`/`python` stubs in the packages path.

REZ_VERSION="${REZ_VERSION:-3.4.0}"
REZ_INSTALL_DIR="${REZ_INSTALL_DIR:-/opt/rez}"
REZ_TARBALL_SHA256="${REZ_TARBALL_SHA256:-bcef8c8d04c9846d2369b04fad2a22c1e6761c3b5a60ebe13cc42169152c3d1f}"
REZ_TARBALL_URL="${REZ_TARBALL_URL:-https://github.com/AcademySoftwareFoundation/rez/releases/download/${REZ_VERSION}/${REZ_VERSION}.tar.gz}"
REZ_BIN="${REZ_INSTALL_DIR}/bin/rez/rez"

install_rez_from_tarball() {
    local tmpdir workdir tarball
    tmpdir="$(mktemp -d)" || return 1
    tarball="${tmpdir}/rez-${REZ_VERSION}.tar.gz"
    echo "=== Installing Rez ${REZ_VERSION} (source install) ==="
    echo "Downloading ${REZ_TARBALL_URL}"
    curl -fsSL -o "${tarball}" "${REZ_TARBALL_URL}" || {
        echo "ERROR: failed to download Rez tarball" >&2
        rm -rf "${tmpdir}"
        return 1
    }
    echo "Verifying sha256 (pinned ${REZ_TARBALL_SHA256})"
    if command -v sha256sum >/dev/null 2>&1; then
        echo "${REZ_TARBALL_SHA256}  ${tarball}" | sha256sum -c - >/dev/null || {
            echo "ERROR: sha256 mismatch for Rez tarball" >&2
            rm -rf "${tmpdir}"
            return 1
        }
    elif command -v shasum >/dev/null 2>&1; then
        [ "$(shasum -a 256 "${tarball}" | awk '{print $1}')" = "${REZ_TARBALL_SHA256}" ] || {
            echo "ERROR: sha256 mismatch for Rez tarball" >&2
            rm -rf "${tmpdir}"
            return 1
        }
    else
        echo "ERROR: no sha256 tool available" >&2
        rm -rf "${tmpdir}"
        return 1
    fi
    workdir="${tmpdir}/src"
    mkdir -p "${workdir}" || {
        rm -rf "${tmpdir}"
        return 1
    }
    tar -xzf "${tarball}" -C "${workdir}" --strip-components 1 || {
        rm -rf "${tmpdir}"
        return 1
    }
    mkdir -p "${REZ_INSTALL_DIR}" || {
        rm -rf "${tmpdir}"
        return 1
    }
    (cd "${workdir}" && python3 install.py "${REZ_INSTALL_DIR}") || {
        rm -rf "${tmpdir}"
        return 1
    }
    rm -rf "${tmpdir}"
}

if [ ! -x "${REZ_BIN}" ]; then
    install_rez_from_tarball || {
        echo "ERROR: Rez source install failed" >&2
        return 1
    }
elif "${REZ_BIN}" --version 2>/dev/null | grep -q "${REZ_VERSION}"; then
    echo "=== Rez ${REZ_VERSION} already installed at ${REZ_INSTALL_DIR}; skipping ==="
else
    echo "WARNING: existing Rez at ${REZ_BIN} is not ${REZ_VERSION}; reinstalling" >&2
    install_rez_from_tarball || {
        echo "ERROR: Rez source install failed" >&2
        return 1
    }
fi

REZ_BIN_DIR="$(cd "$(dirname "${REZ_BIN}")" && pwd)" || return 1
case ":${PATH:-}:" in
    *":${REZ_BIN_DIR}:"*) ;;
    *) export PATH="${REZ_BIN_DIR}:${PATH}" ;;
esac

echo "rez --version:"
"${REZ_BIN}" --version || return 1
echo "=== Rez install complete ==="
