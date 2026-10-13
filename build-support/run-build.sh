#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/vfx-cxx.sh"
vfx_cxx_environment
export DESTDIR=/opt/install
bash "$1"
