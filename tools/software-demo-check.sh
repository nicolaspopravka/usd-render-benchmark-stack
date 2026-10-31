#!/bin/bash
set -euo pipefail
mkdir results
python3 tools/build.py profiles/cy2027.json 2>&1 | tee results/build.log
image=$(sed -n 's/^Runnable: //p' results/build.log | tail -1)
out="$PWD/results/cy2027"
mkdir -p "$out"
docker inspect --format '{{.Id}} {{json .RepoDigests}} {{json .Config.Labels}}' "$image" > "$out/image.txt"
git clone --depth 1 --branch demo/run1 --single-branch https://github.com/nicolaspopravka/usd-render-benchmark.git demo
run="$PWD/demo"
git -C "$run" checkout b7fb867ca850da5e89c409475cd681da685cc5a7
git -C "$run" submodule update --init assets
git -C "$run" rev-parse HEAD > "$out/checkout.txt"
git -C "$run" submodule status > "$out/assets.txt"
mkdir "$run/previous"
mv "$run/logs" "$run/renderers" "$run/render_summary.md" "$run/previous/"
set +e
docker run --rm --platform linux/amd64 \
  --mount "type=bind,source=$run,target=/benchmark" \
  --env REZ_PACKAGES_PATH=/benchmark/packages \
  --workdir /benchmark --entrypoint bash "$image" -c '
    set -e
    rpm -qa | sort | grep -E "^(mesa|llvm|libglvnd)" > packages-before.txt
    if [ -r /usr/local/lib/dri/swrast_dri.so ]; then
      export LIBGL_DRIVERS_PATH=/usr/local/lib/dri
      echo supplied-driver > driver-selection.txt
    else
      dnf install -y --disablerepo=cuda mesa-dri-drivers
      echo system-driver > driver-selection.txt
    fi
    rpm -qa | sort | grep -E "^(mesa|llvm|libglvnd)" > packages-after.txt
    for f in /usr/local/lib/dri/swrast_dri.so /usr/lib64/dri/swrast_dri.so /usr/lib/dri/swrast_dri.so /usr/local/lib/libOSMesa.so.8 /usr/lib64/libOSMesa.so.8; do
      if [ -e "$f" ]; then
        echo "FILE $f"; readlink -f "$f"; ls -l "$f"
        readelf -d "$f" || true
        ldd "$f" || true
      fi
    done > driver-libraries.txt 2>&1
    LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a bash render_script.sh
    python3 generate_render_summary.py --system-specs "CY2027 software demo"
    test -s renderers/GL/Teapot.jpg
    if grep -q "ERROR: usdrecord returned non-zero exit status" logs/GL_Teapot.log; then exit 1; fi
    cp -a logs ordinary-logs
    LIBGL_ALWAYS_SOFTWARE=1 LD_DEBUG=libs xvfb-run -a bash render_script.sh > loader-trace.log 2>&1
    grep "calling init:" loader-trace.log > initialized-libraries.log
    if grep -q "ERROR: usdrecord returned non-zero exit status" logs/GL_Teapot.log; then exit 1; fi
  ' 2>&1 | tee "$out/container.log"
status=${PIPESTATUS[0]}
set -e
printf 'container=%s\n' "$status" > "$out/status.txt"
for item in logs ordinary-logs renderers render_summary.md packages-before.txt packages-after.txt driver-selection.txt driver-libraries.txt initialized-libraries.log; do
  if [[ -e "$run/$item" ]]; then sudo cp -a "$run/$item" "$out/"; fi
done
exit "$status"
