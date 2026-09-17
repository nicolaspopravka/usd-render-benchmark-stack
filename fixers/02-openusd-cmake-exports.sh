#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Provide the CONAN_LIB:: imported targets that the deployed OpenUSD cmake
# exports reference but the ASWF conan deploy never defines.
#
# Root cause: the deployed pxrTargets.cmake set_target_properties() calls for
# the installed USD targets reference Conan-generated names such as
#   CONAN_LIB::boost_Boost_python_boost_python310_RELEASE
#   CONAN_LIB::materialx_materialx_MaterialXCore_MaterialXCore_RELEASE
#   CONAN_LIB::ptex_Ptex_Ptex_dynamic_Ptex_RELEASE
# while the deploy installs only the libraries, not the conan generator files
# that define these targets. Observed on the ci-moonray 2023.5/2024.9/2025.8
# bases (pristine build runs for 2023.2/2024.2/2025.2).
#
# The dependencies are already linked into the installed OpenUSD libraries, so
# an empty INTERFACE IMPORTED target is enough for consumers; a real need would
# surface as an undefined symbol at MoonRay link time.
#
# DROP THIS when the ASWF bases ship corrected OpenUSD cmake exports.
set -euo pipefail

python3 - <<'PYEOF'
import re
from pathlib import Path

pxr_config = Path("/usr/local/pxrConfig.cmake")
targets = sorted(Path("/usr/local/cmake").glob("pxrTargets*.cmake"))
if not (pxr_config.is_file() and targets):
    raise SystemExit("OpenUSD cmake exports not found at /usr/local")
files = [pxr_config, *targets]

stray = sorted({
    n
    for p in files
    for n in re.findall(r"CONAN_LIB::([A-Za-z0-9_]+)", p.read_text())
})
if not stray:
    print("OpenUSD cmake exports: no residual CONAN_LIB targets")
    raise SystemExit(0)

marker = "# ASWF deployed-image dependency shim for OpenMoonRay"
includes = 'include("${PXR_CMAKE_DIR}/cmake/pxrTargets.cmake")'
text = pxr_config.read_text()
if marker in text:
    print("OpenUSD cmake exports: shim already present")
    raise SystemExit(0)
if includes not in text:
    raise SystemExit("cannot locate pxrTargets include in pxrConfig.cmake")

lines = [
    marker,
    "# Residual CONAN_LIB boost/python targets in older-cycle exports",
    "# (deps already linked into the installed OpenUSD libraries).",
]
for name in stray:
    lines += [
        f"if(NOT TARGET CONAN_LIB::{name})",
        f"    add_library(CONAN_LIB::{name} INTERFACE IMPORTED)",
        "endif()",
        "",
    ]
pxr_config.write_text(text.replace(includes, "\n".join(lines) + includes, 1))
print(f"OpenUSD cmake exports: synthesized {len(stray)} CONAN_LIB interface targets")
PYEOF