#!/usr/bin/env bash
# Activate the selected compiler settings in each independent build shell.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/vfx-cxx.sh"
vfx_cxx_environment
bash "$1"
