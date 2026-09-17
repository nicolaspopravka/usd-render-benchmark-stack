#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Provide an OpenVDB CMake config for pxrConfig's find_dependency(OpenVDB).
#
# Root cause: pxrConfig.cmake:133 (USD 26.08) calls find_dependency(OpenVDB),
# but the ASWF OpenVDB deploy ships no findable CMake config on some bases
# (OpenVDB 13.0 on the 2027 image, pristine run 35246204686). The dependency is
# already linked into the installed OpenUSD libraries, so a stub config
# reporting FOUND (with an empty OpenVDB::openvdb interface matching the
# pxrTargets signature) is enough for consumers.
#
# Kept separate from 02-openusd-cmake-exports.sh because it is consumer-
# independent and drops on its own condition: it concerns the pxrConfig
# find_dependency graph, not the pxrTargets imported-target synthesis, so only
# the pxr-package consumers that hit the >=26.08 pxrConfig need it (Embree;
# MoonRay's CY2026/27 builds are blocked upstream).
#
# DROP THIS when the ASWF bases ship an OpenVDB cmake config (or pxrConfig
# stops find_dependency-ing OpenVDB).
set -euo pipefail

if [ -e /usr/local/lib/cmake/OpenVDB/OpenVDBConfig.cmake ] \
   || [ -e /usr/local/cmake/OpenVDBConfig.cmake ]; then
    echo "OpenVDB: deploy ships a cmake config; no stub needed"
    exit 0
fi

mkdir -p /usr/local/lib/cmake/OpenVDB
cat > /usr/local/lib/cmake/OpenVDB/OpenVDBConfig.cmake <<'EOF'
# ASWF deployed-image shim: OpenVDB's cmake config is not deployed; the
# dependency is already linked into the installed OpenUSD libraries.
if(NOT TARGET OpenVDB::openvdb)
    add_library(OpenVDB::openvdb INTERFACE IMPORTED)
endif()
set(OpenVDB_FOUND TRUE)
EOF
echo "OpenVDB: stub OpenVDBConfig.cmake written (pxrConfig find_dependency(OpenVDB))"