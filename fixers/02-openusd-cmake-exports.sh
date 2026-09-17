#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Patch the deployed OpenUSD cmake exports that the MoonRay build consumes.
#
# Root cause: the ASWF conan deploy ships OpenUSD's cmake configs with
# Conan-generated imported-target names (CONAN_LIB::prop_component_..._RELEASE)
# that the deploy never defines (it installs the libraries, not the conan
# generator files). The installed USD libraries already carry the dependencies,
# but the pxrTargets.cmake set_target_properties() calls fail for external
# consumers such as MoonRay's find_package(pxr).
#
# Scope notes:
#   - The #449-era re-released bases no longer carry stale /opt/conan_home path
#     hints; this fixer only handles the target-name classes seen on 23.08/24.08.
#   - MaterialX/Ptex names are REWRITTEN to the real shipped targets (MoonRay
#     genuinely links MaterialX); residual boost/python CONAN_LIB targets are
#     synthesized as empty INTERFACE IMPORTED (deps already linked into USD).
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

marker = "# ASWF deployed-image dependency shim for OpenMoonRay"

# Real target names the ASWF deploy ships: MaterialX is un-namespaced
# (MaterialXCore, ...); Ptex is a namespaced imported target on these cycles.
materialx_conan = re.compile(
    r"CONAN_LIB::materialx_materialx_(?P<c>[A-Za-z0-9]+)_(?P=c)_RELEASE"
)
ptex_conan = re.compile(
    r"CONAN_LIB::ptex_Ptex_(?P<c>[A-Za-z0-9_]+?)_Ptex_RELEASE"
)

for path in files:
    text = path.read_text()
    if path.name.startswith("pxrTargets") or path.name.startswith("pxrConfig"):
        text = materialx_conan.sub(lambda m: m.group("c"), text)
        text = ptex_conan.sub(lambda m: "Ptex::" + m.group("c"), text)
    path.write_text(text)

# The exports reference imported targets the conan deploy does not load itself;
# provide the ones these cycles need. Ptex ships a cmake config on some years;
# on others it does not, so synthesize it. OpenSubdiv's own config uses the
# lowercase spellings on 25.05+; older cycles export the uppercase variants, so
# both capitalizations are provided.
text = pxr_config.read_text()
includes = 'include("${PXR_CMAKE_DIR}/cmake/pxrTargets.cmake")'
if marker not in text:
    block = f"""{marker}
# The deployed pxr exports reference imported targets that consumers must
# provide (the conan deploy does not load them itself).
find_package(Threads REQUIRED)
if(EXISTS "/usr/local/lib/cmake/Ptex")
    find_package(Ptex CONFIG REQUIRED)
else()
    if(NOT TARGET Ptex::Ptex_dynamic)
        add_library(Ptex::Ptex_dynamic SHARED IMPORTED)
        set_target_properties(Ptex::Ptex_dynamic PROPERTIES
            IMPORTED_LOCATION "/usr/local/lib/libPtex.so"
            INTERFACE_INCLUDE_DIRECTORIES "/usr/local/include")
    endif()
endif()
find_package(OpenColorIO CONFIG REQUIRED)
find_package(MaterialX CONFIG REQUIRED)
if(NOT TARGET OpenSubdiv::osdcpu)
    add_library(OpenSubdiv::osdcpu SHARED IMPORTED)
    set_target_properties(OpenSubdiv::osdcpu PROPERTIES
        IMPORTED_LOCATION "/usr/local/lib/libosdCPU.so"
        INTERFACE_INCLUDE_DIRECTORIES "/usr/local/include")
endif()
if(NOT TARGET OpenSubdiv::osdgpu)
    add_library(OpenSubdiv::osdgpu SHARED IMPORTED)
    set_target_properties(OpenSubdiv::osdgpu PROPERTIES
        IMPORTED_LOCATION "/usr/local/lib/libosdGPU.so"
        INTERFACE_INCLUDE_DIRECTORIES "/usr/local/include")
endif()
# Older-cycle exports (23.08/24.08) spell these with an uppercase CPU/GPU;
# target names are case-sensitive, so provide both capitalizations.
if(NOT TARGET OpenSubdiv::osdCPU)
    add_library(OpenSubdiv::osdCPU SHARED IMPORTED)
    set_target_properties(OpenSubdiv::osdCPU PROPERTIES
        IMPORTED_LOCATION "/usr/local/lib/libosdCPU.so"
        INTERFACE_INCLUDE_DIRECTORIES "/usr/local/include")
endif()
if(NOT TARGET OpenSubdiv::osdGPU)
    add_library(OpenSubdiv::osdGPU SHARED IMPORTED)
    set_target_properties(OpenSubdiv::osdGPU PROPERTIES
        IMPORTED_LOCATION "/usr/local/lib/libosdGPU.so"
        INTERFACE_INCLUDE_DIRECTORIES "/usr/local/include")
endif()

{includes}"""
    if includes not in text:
        raise SystemExit("cannot locate pxrTargets include in pxrConfig.cmake")
    pxr_config.write_text(text.replace(includes, block, 1))

# Residual CONAN_LIB:: targets (boost/python components the deploy never
# defines). The dependencies are already linked into the installed OpenUSD
# libraries, so an empty INTERFACE IMPORTED target is enough for consumers; a
# real need would surface as an undefined symbol at MoonRay link time.
stray = sorted({
    n
    for p in files
    for n in re.findall(r"CONAN_LIB::([A-Za-z0-9_]+)", p.read_text())
})
if stray:
    lines = [
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
    synth = "\n".join(lines) + includes
    text = pxr_config.read_text()
    if includes not in text:
        raise SystemExit("cannot locate pxrTargets include in pxrConfig.cmake")
    pxr_config.write_text(text.replace(includes, synth, 1))
    print(f"OpenUSD cmake exports: rewire MaterialX/Ptex, imports block added, "
          f"{len(stray)} residual CONAN_LIB interface targets synthesized")
else:
    print("OpenUSD cmake exports: no residual CONAN_LIB targets")
PYEOF