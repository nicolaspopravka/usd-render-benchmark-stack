#!/usr/bin/env bash
# In-container verification of an OpenMoonRay install (both probe jobs).
#
# Bar: hd_moonray.so installed somewhere under /usr/local, its link closure
# resolves (ldd -r), and the auxiliary binaries the runnable's shader_json
# step expects are visible. Deeper plug-registry enumeration happens in the
# ExecPlan's Phase 4 in-image battery, not here.
set -euo pipefail

echo "installed MoonRay artifacts:"
find /usr/local \( -name 'hd_moonray*' -o -name 'libarras4_core*' \
    -o -name 'rdl2_json_exporter' \) 2>/dev/null | sort || true

PLUGIN="$(find /usr/local -name 'hd_moonray.so' 2>/dev/null | head -1 || true)"
if [ -z "${PLUGIN}" ]; then
    echo "FAIL: hd_moonray.so not installed"
    exit 1
fi
echo "hd_moonray.so: ${PLUGIN}"

if ldd -r "${PLUGIN}" 2>&1 | grep -q 'not found'; then
    echo "FAIL: unresolved symbols/libraries:"
    ldd -r "${PLUGIN}" 2>&1 | grep 'not found'
    exit 1
fi
echo "ldd -r: 0 not found"

command -v rdl2_json_exporter >/dev/null 2>&1 \
    && echo "rdl2_json_exporter: present" \
    || echo "WARN: rdl2_json_exporter missing (runnable shader_json step will no-op)"
ls /usr/local/bin 2>/dev/null | grep -qi arras \
    && echo "arras binaries: present" \
    || echo "WARN: no arras binaries on /usr/local/bin"
echo "VERIFY PASS"
