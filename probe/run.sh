#!/usr/bin/env bash
# Disposable CY2025 diagnostic. Run from the pinned demo checkout in /benchmark.
set -euo pipefail
mkdir -p /results
exec > >(tee /results/session.log) 2>&1
run() {
    local name=$1 status
    shift
    printf 'COMMAND:'; printf ' %q' "$@"; printf '\n'
    if "$@" >"/results/$name.log" 2>&1; then status=0; else status=$?; fi
    cat "/results/$name.log"
    printf '%s=%s\n' "$name" "$status" | tee -a /results/status.txt
    return "$status"
}
test "${ASWF_VFXPLATFORM_VERSION:-}" = 2025
test -f assets/full_assets/Teapot/Teapot.usd
test -x /usr/local/bin/llvm-config
test "$('/usr/local/bin/llvm-config' --version | cut -d. -f1)" = 18
test ! -e /results/status.txt
env | sort > /results/environment.txt
run llvm-config /usr/local/bin/llvm-config --version --shared-mode --libdir --targets-built
run llvm-shared /usr/local/bin/llvm-config --link-shared --libfiles
# Install build/context prerequisites, leaving ASWF's LLVM and delegates intact.
run prerequisites timeout 300 dnf install -y --disablerepo=cuda \
    bison flex expat-devel zlib-devel libX11-devel libXext-devel libXfixes-devel \
    libXdamage-devel libXrandr-devel libXxf86vm-devel libxcb-devel \
    libxshmfence-devel libdrm-devel libglvnd-devel elfutils-libelf-devel \
    xorg-x11-server-Xvfb xorg-x11-xauth mesa-dri-drivers
python3 -m venv /tmp/issue58-build-python
run python-build-tools /tmp/issue58-build-python/bin/pip install \
    meson==1.7.0 Mako==1.3.10 packaging==24.2 PyYAML==6.0.2
export PATH=/tmp/issue58-build-python/bin:$PATH
run fetch-mesa curl -fL --retry 2 --max-time 180 \
    https://archive.mesa3d.org/mesa-24.3.4.tar.xz -o /tmp/mesa-24.3.4.tar.xz
printf '%s\n' 'e641ae27191d387599219694560d221b7feaa91c900bcec46bf444218ed66025  /tmp/mesa-24.3.4.tar.xz' | sha256sum -c -
tar -xJf /tmp/mesa-24.3.4.tar.xz -C /tmp
cat > /tmp/issue58-native.ini <<'EOF'
[binaries]
llvm-config = '/usr/local/bin/llvm-config'
EOF
# No AMD driver: Mesa needs only LLVM's native CPU target. Force shared LLVM
# so its command-line registry is not copied into another shared object.
run mesa-configure meson setup /tmp/issue58-mesa-build /tmp/mesa-24.3.4 \
    --native-file /tmp/issue58-native.ini --prefix=/opt/issue58-mesa --libdir=lib \
    --buildtype=release --wrap-mode=nofallback \
    -Dplatforms=x11 -Dgallium-drivers=llvmpipe -Dvulkan-drivers=[] \
    -Dllvm=enabled -Dshared-llvm=enabled -Dglx=dri -Dglvnd=enabled \
    -Degl=disabled -Dgbm=disabled -Dgles1=disabled -Dgles2=disabled \
    -Dgallium-va=disabled -Dgallium-vdpau=disabled -Dgallium-opencl=disabled \
    -Dbuild-tests=false
run mesa-build timeout 1800 ninja -C /tmp/issue58-mesa-build -j2
run mesa-install meson install -C /tmp/issue58-mesa-build
run driver-linkage ldd /opt/issue58-mesa/lib/libgallium-24.3.4.so
grep -F '/usr/local/lib/libLLVM' /results/driver-linkage.log
if grep -E 'not found|libLLVM-17|llvm17' /results/driver-linkage.log; then exit 2; fi

original_library_path=${LD_LIBRARY_PATH:-}
failed=0
for renderer in GL Cycles; do
    # The baseline is run after dependency installation, in a separate process.
    # Both render attempts use the same scene, delegate binaries and packages.
    run "baseline-$renderer" timeout 120 env -u MESA_SHADER_CACHE_DISABLE \
        LIBGL_ALWAYS_SOFTWARE=1 MESA_SHADER_CACHE_DIR="/results/cache-baseline-$renderer" \
        xvfb-run -a rez env aswf -- usdrecord --camera main_cam --renderer "$renderer" \
        --purposes render assets/full_assets/Teapot/Teapot.usd \
        "/results/baseline-$renderer.jpg" || true
    if ! run "matched-$renderer" timeout 120 env -u MESA_SHADER_CACHE_DISABLE \
        LD_LIBRARY_PATH="/opt/issue58-mesa/lib:$original_library_path" \
        __GLX_VENDOR_LIBRARY_NAME=mesa \
        GALLIUM_DRIVER=llvmpipe LIBGL_ALWAYS_SOFTWARE=1 \
        MESA_SHADER_CACHE_DIR="/results/cache-matched-$renderer" \
        xvfb-run -a rez env aswf -- env LD_DEBUG=libs \
        LD_DEBUG_OUTPUT="/results/matched-$renderer-loader" \
        usdrecord --camera main_cam --renderer "$renderer" --purposes render \
        assets/full_assets/Teapot/Teapot.usd "/results/matched-$renderer.jpg"; then
        failed=1
    fi
done
python3 - <<'PY'
import gzip
from pathlib import Path

root = Path('/results')
failed = False
for renderer, plugin in [('GL', 'HdStormRendererPlugin'), ('Cycles', 'HdCyclesPlugin')]:
    log = (root / f'matched-{renderer}.log').read_text()
    if f'Renderer plugin: {plugin}' not in log:
        print(f'{renderer}: expected plugin missing')
        failed = True
    output = root / f'matched-{renderer}.jpg'
    if not output.exists() or not output.stat().st_size:
        print(f'{renderer}: fresh output missing')
        failed = True
    traces = list(root.glob(f'matched-{renderer}-loader.*'))
    initialized = set()
    for trace in traces:
        for line in trace.read_text(errors='replace').splitlines():
            if 'calling init:' in line and 'libLLVM' in line:
                initialized.add(line.split('calling init:', 1)[1].strip())
        with gzip.open(str(trace) + '.gz', 'wb') as target:
            target.write(trace.read_bytes())
        trace.unlink()
    print(f'{renderer}: initialized LLVM libraries: {sorted(initialized)}')
    if len(initialized) != 1 or not all(p.startswith('/usr/local/lib/') for p in initialized):
        failed = True
raise SystemExit(1 if failed else 0)
PY
exit "$failed"
