#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Provision the compiler toolset the OpenMoonRay build runs with.
#
# The ASWF CY2026+ images default to gcc-toolset-14, which is too new twice
# over for OpenMoonRay: nvcc (CUDA 12.9) cannot host-compile with GCC 14 at
# all, and GCC 13+ dropped the transitive standard-library includes the
# MoonRay sources rely on (scene_rdl2 AffinityResourceControl.cc fails with
# "'sort' is not a member of 'std'"). gcc-toolset-12 predates both breaks and
# is inside nvcc's supported host range, so the recipe builds MoonRay with it
# while the rest of the image keeps the default toolset.
#
# MOONRAY_TOOLSET empty = no install, keep the image default compiler (the
# behaviour of every CMake-3.x-era year).
#
# DROP THIS when OpenMoonRay's sources build with the ASWF default toolset.
set -euo pipefail

MOONRAY_TOOLSET="${MOONRAY_TOOLSET:-}"

if [ -z "${MOONRAY_TOOLSET}" ]; then
    echo "MOONRAY_TOOLSET empty; using the image default compiler"
    exit 0
fi

GXX="/opt/rh/${MOONRAY_TOOLSET}/root/usr/bin/g++"
if [ ! -x "${GXX}" ]; then
    dnf -y install --quiet "${MOONRAY_TOOLSET}" "${MOONRAY_TOOLSET}-gcc-c++"
    dnf clean all
    rm -rf /var/cache/dnf
fi
test -x "${GXX}"
echo "${MOONRAY_TOOLSET} ready: $("${GXX}" --version | head -1)"
