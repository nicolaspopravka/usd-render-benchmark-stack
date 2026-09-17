#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Provide the imported targets that the deployed OpenUSD cmake exports
# reference but the ASWF conan deploy never defines.
#
# Root cause: the deployed pxrTargets.cmake set_target_properties() calls for
# the installed USD targets reference dependency targets that do not exist in
# the deploy, e.g.
#   CONAN_LIB::boost_Boost_python_boost_python310_RELEASE
#   CONAN_LIB::materialx_materialx_MaterialXCore_MaterialXCore_RELEASE
#   CONAN_LIB::ptex_Ptex_Ptex_dynamic_Ptex_RELEASE
#   OpenSubdiv::osdCPU / OpenSubdiv::osdGPU
#   OpenColorIO::OpenColorIO
# and OpenSubdiv::osdGPU's link interface references Threads::Threads without
# the config loading it. The deploy installs only the libraries, not the conan
# generator files. Observed on the ci-moonray 2023.5/2024.9 bases (pristine
# build runs 35193000093 / 35196329050 / 35197608340) and the 2025.8 basis
# (35198047442) for the Threads::Threads case.
#
# The dependencies are already linked into the installed OpenUSD libraries, so
# an empty INTERFACE IMPORTED target is enough for consumers; a real need would
# surface as an undefined symbol at MoonRay link time. Threads::Threads is a
# standard CMake module target, so find_package(Threads) defines it.
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

# Every namespaced imported-target reference the exports use (CONAN_LIB::*,
# OpenSubdiv::*, OpenColorIO::*, ...). Pxr's own targets are un-namespaced, so
# they are not matched. Tokens containing `${` are variables, not targets.
stray = sorted({
    tok
    for p in files
    for tok in re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*::[A-Za-z_][A-Za-z0-9_]*\b", p.read_text())
    if "$" not in tok
})
if not stray:
    print("OpenUSD cmake exports: no undefined imported targets")
    raise SystemExit(0)

marker = "# ASWF deployed-image dependency shim for OpenMoonRay"
includes = 'include("${PXR_CMAKE_DIR}/cmake/pxrTargets.cmake")'
text = pxr_config.read_text()
if marker in text:
    print("OpenUSD cmake exports: shim already present")
    raise SystemExit(0)
if includes not in text:
    raise SystemExit("cannot locate pxrTargets include in pxrConfig.cmake")

# Define Threads::Threads before the find_dependency section (the deployed
# OpenSubdiv config references it in osdGPU's link interface without loading it).
text = f"{marker}\nfind_package(Threads REQUIRED)\n\n{text}"

# Synthetic imported targets before pxrTargets include
lines = [
    "# Imported targets the deployed OpenUSD exports reference but the ASWF",
    "# conan deploy never defines (deps already linked into the installed USD",
    "# libraries; an empty interface is enough for consumers).",
]
for name in stray:
    lines += [
        f"if(NOT TARGET {name})",
        f"    add_library({name} INTERFACE IMPORTED)",
        "endif()",
        "",
    ]
pxr_config.write_text(text.replace(includes, "\n".join(lines) + includes, 1))
print(f"OpenUSD cmake exports: synthesized {len(stray)} imported interface targets: {', '.join(stray)}")
PYEOF

# pxrConfig.cmake's find_dependency(OpenVDB) fails on cycles whose ASWF OpenVDB
# deploy ships no findable CMake config (OpenVDB 13.0 on the 2027 base, run
# 35246204686; 26.08 pxrConfig:133). The dependency is already linked into the
# installed USD libraries, so a stub config reporting FOUND (with an empty
# interface matching the pxrTargets signature) is enough. Written only when the
# deploy ships no config.
if [ ! -e /usr/local/lib/cmake/OpenVDB/OpenVDBConfig.cmake ] \
   && [ ! -e /usr/local/cmake/OpenVDBConfig.cmake ]; then
    mkdir -p /usr/local/lib/cmake/OpenVDB
    cat > /usr/local/lib/cmake/OpenVDB/OpenVDBConfig.cmake <<'EOF'
# ASWF deployed-image shim: OpenVDB's cmake config is not deployed; the
# dependency is already linked into the installed OpenUSD libraries.
if(NOT TARGET OpenVDB::openvdb)
    add_library(OpenVDB::openvdb INTERFACE IMPORTED)
endif()
set(OpenVDB_FOUND TRUE)
EOF
    echo "OpenUSD cmake exports: stub OpenVDBConfig.cmake written (find_dependency(OpenVDB))"
fi