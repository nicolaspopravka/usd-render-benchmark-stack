#!/usr/bin/env bash
# Native compatibility check only: no images, benchmark results or test fixtures.
set -uo pipefail
root="${VALIDATION_ROOT:?Set VALIDATION_ROOT}"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
patch="$repo_root/build-support/compat/cycles-nanovdb-default.patch"
evidence="$root/evidence"
mkdir -p "$evidence"
exec > >(tee "$evidence/driver.log") 2>&1
usd_ref=3ed9ded5b9a8469e0f37525afbbad95c1e09f2a8
cycles_ref=6abef8c62bf9d6896a81faf86bfd96121802a7be
prefix="$root/usd-install"
collect_sdk_logs() {
  if [ -d "$prefix/build" ]; then
    find "$prefix/build" \( -name log.txt -o -name CMakeCache.txt \) -exec cp --parents '{}' "$evidence/" \;
  fi
}
trap collect_sdk_logs EXIT
run_step() {
  local name="$1"; shift
  printf 'Starting %s\n' "$name"
  "$@" > "$evidence/$name.log" 2>&1
  local status=$?
  printf '%s=%s\n' "$name" "$status" | tee -a "$evidence/status.txt"
  return "$status"
}
printf 'usd_ref=%s\ncycles_ref=%s\n' "$usd_ref" "$cycles_ref" > "$evidence/inputs.txt"
sha256sum "$patch" >> "$evidence/inputs.txt"
g++ --version > "$evidence/compiler.txt"
cmake --version > "$evidence/cmake.txt"
python -m pip freeze > "$evidence/python-packages.txt"
git clone --depth 1 --branch dev https://github.com/PixarAnimationStudios/OpenUSD.git "$root/usd-source" || exit 70
if [ "$(git -C "$root/usd-source" rev-parse HEAD)" != "$usd_ref" ]; then
  git -C "$root/usd-source" fetch --depth 1 origin "$usd_ref" || exit 71
  git -C "$root/usd-source" checkout --detach "$usd_ref" || exit 72
fi
cd "$root/usd-source" || exit 73
run_step usd-build python build_scripts/build_usd.py "$prefix" || exit 1
find "$prefix/build" -name CMakeCache.txt -exec cp --parents '{}' "$evidence/" \;
export PATH="$prefix/bin:$PATH"
export PYTHONPATH="$prefix/lib/python"
export LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# Share only downloaded LFS objects; each checkout/build remains isolated.
git config --global lfs.storage "$root/lfs-cache"
failed=0
for label in baseline candidate; do
  source_dir="$root/$label"
  git clone --depth 1 https://projects.blender.org/blender/cycles.git "$source_dir" || exit 74
  if [ "$(git -C "$source_dir" rev-parse HEAD)" != "$cycles_ref" ]; then
    git -C "$source_dir" fetch --depth 1 origin "$cycles_ref" || exit 75
  fi
  git -C "$source_dir" checkout --detach "$cycles_ref" || exit 76
  cd "$source_dir" || exit 77
  if [ "$label" = candidate ]; then git apply --check "$patch" && git apply "$patch" || exit 78; fi
  git diff > "$evidence/$label-source.diff"
  run_step "$label-update" make update || { failed=1; continue; }
  git -C lib/linux_x64 rev-parse HEAD > "$evidence/$label-bundle.txt"
  run_step "$label-configure" cmake -B ./build -DPXR_ROOT="$prefix" || { failed=1; continue; }
  cp build/CMakeCache.txt "$evidence/$label-CMakeCache.txt"
  run_step "$label-build" make || { failed=1; continue; }
  export PXR_PLUGINPATH_NAME="$source_dir/install/hydra"
  run_step "$label-plugin" python -c 'from pxr import Plug; p=next(p for p in Plug.Registry().GetAllPlugins() if p.name=="hdCycles"); print(p.path); p.Load(); print("loaded",p.isLoaded); assert p.isLoaded' || failed=1
  ldd install/hydra/hdCycles.so > "$evidence/$label-ldd.txt" 2>&1 || true
done
exit "$failed"
