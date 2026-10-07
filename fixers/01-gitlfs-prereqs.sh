#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Step-1 prereqs that the aswf/ci-moonray base omits.
#
# Mirrors the official Rocky 9 container build's install_packages.sh, which
# installs git-lfs (the openmoonray superproject's submodules track files via
# LFS), reduced to the packages this base does not already provide.
#
# DROP THIS when git-lfs ships in the ASWF base images.
set -euo pipefail

if ! command -v git-lfs >/dev/null 2>&1; then
    dnf -y install --quiet git-lfs
    dnf clean all
    rm -rf /var/cache/dnf
fi
git lfs install
echo "git-lfs ready: $(git lfs --version)"