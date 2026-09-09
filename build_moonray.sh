#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Build OpenMoonRay into the benchmark's pristine stack image. Runs on
# aswf/ci-moonray:<year>, whose VFX dependencies are already deployed under
# /usr/local. Follows the official Rocky 9 container build:
#   https://docs.openmoonray.org/getting-started/installation/building-moonray/rocky9_container_build
# (step 1, install_packages.sh, is satisfied by the ci-moonray base; OptiX is
# omitted, per the doc's container default).
#
# Non-CY-specific workarounds kept from the earlier fork probe build:
#   - git-lfs prerequisite (the superproject submodules track files via LFS)
#   - OpenUSD cmake-export relocation shim (ASWF conan deploy defect)
#   - Boost header-only "system" component + Asio io_service compat header
#   - official ispc fallback when the deployed ispc cannot execute
#   - CMake>=4 policy flags (version-guarded; no-op on 3.x)
# CY-specific adaptations (CMake-4 flags on CY2027, Ndr tolerance, OptiX 7.6
# pinning, etc.) are deliberately NOT included; surface them from the build
# failure evidence instead.
#
# TEMPORARY: drop this overlay when OpenMoonRay lands in the ASWF base images.
set -euo pipefail

MOONRAY_TAG="${MOONRAY_TAG:-v2026.29.1}"
MOONRAY_COMMIT="${MOONRAY_COMMIT:-d96c6e30a8c280d4b5eb3bafa5e54efc445d7ea8}"
MOONRAY_REPO_URL="${MOONRAY_REPO_URL:-https://github.com/OpenMoonRay/openmoonray.git}"

BUILD_ROOT="$(mktemp -d)"
trap 'rm -rf "${BUILD_ROOT}"' EXIT
MOONRAY_SRC="${BUILD_ROOT}/src"
MOONRAY_BUILD="${BUILD_ROOT}/build"
CMAKE_INSTALL_PREFIX="${CMAKE_INSTALL_PREFIX:-${ASWF_INSTALL_PREFIX:-/usr/local}}"

PYTHON_MAJOR_MINOR="${ASWF_PYTHON_MAJOR_MINOR_VERSION:-$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')}"
BOOST_PYTHON_COMPONENT_NAME="${BOOST_PYTHON_COMPONENT_NAME:-python${PYTHON_MAJOR_MINOR//./}}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
PYBIN="${CMAKE_INSTALL_PREFIX}/bin/python${PYTHON_MAJOR_MINOR}"

# Step 0: prerequisite — openmoonray submodules track some files via Git LFS.
if ! command -v git-lfs >/dev/null 2>&1; then
    dnf -y install --quiet git-lfs
fi
git lfs install

# ispc: MoonRay's ISPC kernels require it on Linux. When the deployed ispc is
# unusable, provision the official release aarch64-independent Linux bundle.
if ! ispc --version >/dev/null 2>&1; then
    echo "WARN: deployed ispc unusable; installing official ispc v1.25.0"
    ISPC_TARBALL="${BUILD_ROOT}/ispc.tar.gz"
    curl --location --fail --silent --show-error -o "${ISPC_TARBALL}" \
        https://github.com/ispc/ispc/releases/download/v1.25.0/ispc-v1.25.0-linux.tar.gz
    echo "1667976049abe6653d170de3f8a462799d57981ce46a161ccf59367f1177a028  ${ISPC_TARBALL}" | sha256sum --check -
    tar -xzf "${ISPC_TARBALL}" -C "${BUILD_ROOT}"
    install -m 0755 "${BUILD_ROOT}/ispc-v1.25.0-linux/bin/ispc" /usr/local/bin/ispc
fi

# OpenUSD cmake-export relocation shim (ASWF conan deploy defect; general).
python3 - <<'PYEOF'
import re
from pathlib import Path

pxr_config = Path("/usr/local/pxrConfig.cmake")
targets = sorted(Path("/usr/local/cmake").glob("pxrTargets*.cmake"))
if not (pxr_config.is_file() and targets):
    raise SystemExit("OpenUSD cmake exports not found at /usr/local")
files = [pxr_config, *targets]

marker = "# ASWF deployed-image dependency relocation for OpenMoonRay"
hint = re.compile(
    r"if \(NOT \[\[/opt/conan_home/d/b/[^\]]+/b/build/Release/generators\]\] STREQUAL \"\"\)\n"
    r"(?P<indent>\s+)set\((?P<package>MaterialX|Imath)_DIR "
    r"\[\[/opt/conan_home/d/b/[^\]]+/b/build/Release/generators\]\]\)"
)

def repl(match):
    package = match.group("package")
    return (
        f'if (NOT [[/usr/local/lib/cmake/{package}]] STREQUAL "")\n'
        f'{match.group("indent")}set({package}_DIR '
        f'[[/usr/local/lib/cmake/{package}]]\u0029'
    )

materialx_conan = re.compile(
    r"CONAN_LIB::materialx_materialx_(?P<c>[A-Za-z0-9]+)_(?P=c)_RELEASE"
)
ptex_conan = re.compile(
    r"CONAN_LIB::ptex_Ptex_(?P<c>[A-Za-z0-9_]+?)_Ptex_RELEASE"
)

for path in files:
    text = path.read_text()
    text, _ = hint.subn(repl, text)
    if path.name.startswith("pxrTargets") or path.name.startswith("pxrConfig"):
        text, _ = materialx_conan.subn(lambda m: m.group("c"), text)
        text, _ = ptex_conan.subn(lambda m: "Ptex::" + m.group("c"), text)
    path.write_text(text)

text = pxr_config.read_text()
includes = 'include("${PXR_CMAKE_DIR}/cmake/pxrTargets.cmake")'
if marker not in text:
    block = f"""{marker}
# The deployed pxr exports reference imported targets that consumers must
# provide (the conan deploy does not load them itself). Ptex ships a cmake
# config on some years; on others it does not, so synthesize it.
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

{includes}"""
    if includes not in text:
        raise SystemExit("cannot locate pxrTargets include in pxrConfig.cmake")
    pxr_config.write_text(text.replace(includes, block, 1))

final = "\n".join(p.read_text() for p in files)
remaining = sorted(set(re.findall(r"/opt/conan_home/[^\"; )\n]+", final)))
if remaining:
    raise SystemExit(f"stale Conan-cache references remain in OpenUSD exports: {remaining}")
print("OpenUSD cmake: corrected stale Conan path hints and synthesized OpenSubdiv targets")

# Boost header-only component shims (same deploy-gap class). Boost's "system"
# component is header-only, so the ASWF deploy ships no boost_system-* package
# for it, but arras4_core requests COMPONENTS system.
BOOST_CMAKE = Path("/usr/local/lib/cmake")
_BOOST_VERSION_H = Path("/usr/local/include/boost/version.hpp")
_BV = 108500
if _BOOST_VERSION_H.is_file():
    m = re.search(r"#define BOOST_VERSION\s+(\d+)", _BOOST_VERSION_H.read_text())
    if m:
        _BV = int(m.group(1))
BOOST_CPP = f"{_BV // 100000}.{_BV // 100 % 1000}.{_BV % 100}"
BOOST_VERSION = BOOST_CPP
for comp in ("system",):
    dir_name = f"boost_{comp}-{BOOST_CPP}"
    pkg_dir = BOOST_CMAKE / dir_name
    pkg_dir.mkdir(parents=True, exist_ok=True)
    config = pkg_dir / f"boost_{comp}-config.cmake"
    version = pkg_dir / f"boost_{comp}-config-version.cmake"
    if not config.exists():
        config.write_text(f"""# ASWF deployed-image dependency shim for OpenMoonRay ({comp} is header-only in Boost {BOOST_VERSION})
if(TARGET Boost::{comp})
  return()
endif()
get_filename_component(_BOOST_CMAKEDIR "${{CMAKE_CURRENT_LIST_DIR}}/../" REALPATH)
get_filename_component(_BOOST_INCLUDEDIR "${{_BOOST_CMAKEDIR}}/../../include/" ABSOLUTE)
if(NOT TARGET Boost::headers)
  add_library(Boost::headers INTERFACE IMPORTED)
  set_target_properties(Boost::headers PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "${{_BOOST_INCLUDEDIR}}")
endif()
add_library(Boost::{comp} INTERFACE IMPORTED)
set_target_properties(Boost::{comp} PROPERTIES INTERFACE_LINK_LIBRARIES Boost::headers)
set(boost_{comp}_FOUND TRUE)
set(boost_{comp}_VERSION {BOOST_VERSION})
""")
    if not version.exists():
        version.write_text(f"""# Generated by Boost {BOOST_VERSION}
set(PACKAGE_VERSION {BOOST_VERSION})
if(PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if(PACKAGE_FIND_VERSION STREQUAL PACKAGE_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif()
endif()
""")

# Boost.Asio io_service -> io_context compatibility header (self-conditional;
# older Boost already ships io_service.hpp).
ASIO_SERVICE = Path("/usr/local/include/boost/asio/io_service.hpp")
if not ASIO_SERVICE.exists() and Path("/usr/local/include/boost/asio").is_dir():
    ASIO_SERVICE.write_text(
        "#ifndef BOOST_ASIO_IO_SERVICE_HPP\n"
        "#define BOOST_ASIO_IO_SERVICE_HPP\n"
        "#include <boost/asio/io_context.hpp>\n"
        "namespace boost { namespace asio {\n"
        "using io_service = io_context;\n"
        "} }\n"
        "#endif\n"
    )
print(f"Boost header-only component shim emitted (v{BOOST_CPP}); Asio io_service compat checked")
PYEOF

# Step 2: clone the superproject (19 submodules) at the pinned tag/commit.
git clone --branch "${MOONRAY_TAG}" --recurse-submodules \
    "${MOONRAY_REPO_URL}" "${MOONRAY_SRC}"
test "$(git -C "${MOONRAY_SRC}" rev-parse HEAD)" = "${MOONRAY_COMMIT}"
git -C "${MOONRAY_SRC}" lfs pull

# Step 3: configure (deps under /usr/local, no OptiX), build, install.
POLICY_ARGS=()
if cmake --version | grep -qE '^cmake version (4|5)\.'; then
    POLICY_ARGS=(-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_POLICY_DEFAULT_CMP0167=NEW)
fi

cmake -S "${MOONRAY_SRC}" -B "${MOONRAY_BUILD}" \
    -G "${OMR_CMAKE_GENERATOR:-Unix Makefiles}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH=/usr/local \
    "${POLICY_ARGS[@]}" \
    -DPYTHON_EXECUTABLE="${PYBIN}" \
    -DPython3_EXECUTABLE="${PYBIN}" \
    -DPython3_LIBRARY="${CMAKE_INSTALL_PREFIX}/lib/libpython${PYTHON_MAJOR_MINOR}.so" \
    -DPython3_INCLUDE_DIR="${CMAKE_INSTALL_PREFIX}/include/python${PYTHON_MAJOR_MINOR}" \
    -DBOOST_PYTHON_COMPONENT_NAME="${BOOST_PYTHON_COMPONENT_NAME}" \
    -DABI_VERSION=0 \
    -DBUILD_QT_APPS=NO \
    -DMOONRAY_USE_OPTIX=NO \
    -DBUILD_MATERIALX_SHADERS="${BUILD_MATERIALX_SHADERS:-OFF}"

cmake --build "${MOONRAY_BUILD}" --parallel "${BUILD_JOBS}"
cmake --install "${MOONRAY_BUILD}" --prefix "${CMAKE_INSTALL_PREFIX}"

# Post-install: export shader_json for the Hydra Ndr plugins (process-scoped).
export PATH="${CMAKE_INSTALL_PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${CMAKE_INSTALL_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
export MOONRAY_ROOT="${CMAKE_INSTALL_PREFIX}"
export RDL2_DSO_PATH="${CMAKE_INSTALL_PREFIX}/rdl2dso.proxy:${CMAKE_INSTALL_PREFIX}/rdl2dso"
export MOONRAY_CLASS_PATH="${CMAKE_INSTALL_PREFIX}/shader_json"

mkdir -p "${CMAKE_INSTALL_PREFIX}/shader_json"
rdl2_json_exporter --out "${CMAKE_INSTALL_PREFIX}/shader_json/" --sparse
echo "OpenMoonRay ${MOONRAY_TAG} installed under ${CMAKE_INSTALL_PREFIX}"