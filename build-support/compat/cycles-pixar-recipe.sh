#!/usr/bin/env bash
# Dependency-alignment candidate; no images or private fixtures are published.
set -uo pipefail
root="${VALIDATION_ROOT:?Set VALIDATION_ROOT}"
mode="${1:?Choose sdk, baseline or candidate}"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
patch="$repo_root/build-support/compat/cycles-nanovdb-default.patch"
sdk_patch="$repo_root/build-support/compat/pixar-onetbb-alignment.patch"
runtime_patch="$repo_root/build-support/compat/cycles-linux-runtime.patch"
evidence="$root/evidence"
mkdir -p "$evidence"
exec > >(tee -a "$evidence/driver.log") 2>&1
usd_ref=3ed9ded5b9a8469e0f37525afbbad95c1e09f2a8
cycles_ref=6abef8c62bf9d6896a81faf86bfd96121802a7be
prefix="$root/usd-install"
collect_sdk_logs() {
  if [ -d "$prefix/build" ]; then
    find "$prefix/build" \( -name log.txt -o -name CMakeCache.txt \) -exec cp --parents '{}' "$evidence/" \;
  fi
}
run_step() {
  local name="$1"; shift
  printf 'Starting %s\n' "$name"
  "$@" > "$evidence/$name.log" 2>&1
  local status=$?
  printf '%s=%s\n' "$name" "$status" | tee -a "$evidence/status.txt"
  return "$status"
}
if [ "$mode" = sdk ]; then
  trap collect_sdk_logs EXIT
  printf 'usd_ref=%s\ncycles_ref=%s\nTBB=2022.3.0\n' "$usd_ref" "$cycles_ref" > "$evidence/inputs.txt"
  sha256sum "$patch" "$sdk_patch" "$runtime_patch" >> "$evidence/inputs.txt"
  g++ --version > "$evidence/compiler.txt"
  cmake --version > "$evidence/cmake.txt"
  python -m pip freeze > "$evidence/python-packages.txt"
  git clone --depth 1 --branch dev https://github.com/PixarAnimationStudios/OpenUSD.git "$root/usd-source" || exit 70
  if [ "$(git -C "$root/usd-source" rev-parse HEAD)" != "$usd_ref" ]; then
    git -C "$root/usd-source" fetch --depth 1 origin "$usd_ref" || exit 71
    git -C "$root/usd-source" checkout --detach "$usd_ref" || exit 72
  fi
  cd "$root/usd-source" || exit 73
  git apply --check "$sdk_patch" && git apply "$sdk_patch" || exit 74
  git diff > "$evidence/usd-source.diff"
  run_step usd-build python build_scripts/build_usd.py "$prefix" || exit 1
  nm -D --defined-only "$prefix/lib/libtbb.so.12" | c++filt > "$evidence/sdk-tbb-exports.txt"
  grep 'get_thread_reference_vertex' "$evidence/sdk-tbb-exports.txt" || exit 75
  sdk_cache="$(find "$prefix/build" -path '*/usd-source/CMakeCache.txt' -print -quit)"
  sed -n 's/^PXR_PYTHON_INSTALL_DIR:STRING=//p' "$sdk_cache" > "$root/sdk-python-install.txt"
  exit 0
fi
case "$mode" in baseline|candidate) ;; *) exit 64;; esac
# Source revisions and documented configure/build commands remain identical in both cases.
label="$mode"
export PATH="$prefix/bin:$PATH"
host_library_path="${LD_LIBRARY_PATH-}"
export LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# Record USD's actual install layout rather than assuming legacy lib/python.
python_install="$(cat "$root/sdk-python-install.txt")"
case "$python_install" in /*) export PYTHONPATH="$python_install";; *) export PYTHONPATH="$prefix/$python_install";; esac
printf 'python_install=%s\n' "$PYTHONPATH" > "$evidence/$label-runtime-environment.txt"
git config --global lfs.storage "$root/lfs-cache"
source_dir="$root/$label"
git clone --depth 1 https://projects.blender.org/blender/cycles.git "$source_dir" || exit 76
if [ "$(git -C "$source_dir" rev-parse HEAD)" != "$cycles_ref" ]; then
  git -C "$source_dir" fetch --depth 1 origin "$cycles_ref" || exit 77
fi
git -C "$source_dir" checkout --detach "$cycles_ref" || exit 78
cd "$source_dir" || exit 79
git apply --check "$runtime_patch" && git apply "$runtime_patch" || exit 80
if [ "$label" = candidate ]; then git apply --check "$patch" && git apply "$patch" || exit 81; fi
git diff > "$evidence/$label-source.diff"
run_step "$label-update" make update || exit 1
git -C lib/linux_x64 rev-parse HEAD > "$evidence/$label-bundle.txt"
run_step "$label-configure" cmake -B ./build -DPXR_ROOT="$prefix" || exit 1
cp build/CMakeCache.txt "$evidence/$label-CMakeCache.txt"
cp build/src/scene/CMakeFiles/cycles_scene.dir/flags.make "$evidence/$label-scene-flags.txt"
run_step "$label-build" make || exit 1
failed=0
export PXR_PLUGINPATH_NAME="$source_dir/install/hydra"
# Load USD before the delegate, as usdview does, so an older already-loaded TBB is not hidden.
run_step "$label-plugin" python -c 'from pxr import Usd, Plug; print("USD", Usd.GetVersion()); p=next(p for p in Plug.Registry().GetAllPlugins() if p.name=="hdCycles"); print(p.path); p.Load(); print("loaded",p.isLoaded); assert p.isLoaded; print("loaded TBB mappings:"); print("".join(line for line in open("/proc/self/maps") if "libtbb" in line))' || failed=1
run_step "$label-executable" install/cycles --help || failed=1
ldd install/hydra/hdCycles.so > "$evidence/$label-ldd.txt" 2>&1 || failed=1
ldd -r install/hydra/hdCycles.so > "$evidence/$label-relocations.txt" 2>&1 || true
# Check the old documented PYTHONPATH separately and retain any layout regression explicitly.
run_step "$label-documented-pythonpath" env PYTHONPATH="$prefix/lib/python" python -c 'from pxr import Usd; print(Usd.GetVersion())' || true
# Relocate the installation and hide the original bundle before testing again.
cp -a install "$root/$label-relocated"
mv lib/linux_x64 "$root/$label-bundle-hidden"
export PXR_PLUGINPATH_NAME="$root/$label-relocated/hydra"
readelf -d "$root/$label-relocated/hydra/hdCycles.so" > "$evidence/$label-installed-dynamic.txt"
run_step "$label-relocated-plugin" python -c 'from pxr import Usd, Plug; print(Usd.GetVersion()); p=next(p for p in Plug.Registry().GetAllPlugins() if p.name=="hdCycles"); p.Load(); print("loaded",p.isLoaded); assert p.isLoaded; print("".join(line for line in open("/proc/self/maps") if "libtbb" in line))' || failed=1
run_step "$label-relocated-executable" "$root/$label-relocated/cycles" --help || failed=1
run_step "$label-no-sdk-ld-path" env LD_LIBRARY_PATH="$host_library_path" python -c 'from pxr import Usd, Plug; p=next(p for p in Plug.Registry().GetAllPlugins() if p.name=="hdCycles"); p.Load(); print("loaded",p.isLoaded); assert p.isLoaded' || failed=1
exit "$failed"
