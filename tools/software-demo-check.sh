#!/bin/bash
set -euo pipefail
mkdir results
python3 tools/build.py profiles/cy2026.json 2>&1 | tee results/build.log
candidate=$(sed -n 's/^Runnable: //p' results/build.log | tail -1)
docker build --progress=plain --build-arg BASE_IMAGE="$candidate" -t mesa-reviewed:2026 tools/mesa-llvm20-reviewed 2>&1 | tee results/mesa-build.log
candidate=mesa-reviewed:2026
for kind in candidate; do
  image="$candidate"
  out="$PWD/results/$kind"
  mkdir -p "$out"
  docker inspect --format '{{.Id}} {{json .RepoDigests}} {{json .Config.Labels}}' "$image" > "$out/image.txt"
  git clone --depth 1 --branch demo/run1 --single-branch https://github.com/nicolaspopravka/usd-render-benchmark.git "demo-$kind"
  run="$PWD/demo-$kind"
  git -C "$run" checkout b7fb867ca850da5e89c409475cd681da685cc5a7
  git -C "$run" submodule update --init assets
  git -C "$run" rev-parse HEAD > "$out/checkout.txt"
  git -C "$run" submodule status > "$out/assets.txt"
  mkdir "$run/previous"
  mv "$run/logs" "$run/renderers" "$run/render_summary.md" "$run/previous/"
  set +e
  docker run --rm --platform linux/amd64     --mount "type=bind,source=$run,target=/benchmark"     --env REZ_PACKAGES_PATH=/benchmark/packages --env LIBGL_DRIVERS_PATH=/usr/local/lib/dri     --workdir /benchmark --entrypoint bash "$image" -c '
      set -e
      dnf install -y --disablerepo=cuda mesa-dri-drivers
      rpm -qa | sort | grep -E "^(mesa|llvm|libglvnd)" > mesa-packages.txt
      ls -l /usr/local/lib/dri > driver.txt
      ldd /usr/local/lib/dri/swrast_dri.so >> driver.txt
      LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a bash render_script.sh
      test -s renderers/GL/Teapot.jpg
      ! grep -q "ERROR: usdrecord returned non-zero exit status" logs/GL_Teapot.log
      cp -a logs ordinary-logs
      if [[ -f renderers/GL/Teapot.jpg ]]; then
        LIBGL_ALWAYS_SOFTWARE=1 LD_DEBUG=libs xvfb-run -a bash render_script.sh > loader-trace.log 2>&1
      fi
      grep "calling init:" loader-trace.log > initialized-libraries.log
      python3 generate_render_summary.py --system-specs "Software-rendered Docker demo"
    ' 2>&1 | tee "$out/container.log"
  status=${PIPESTATUS[0]}
  set -e
  printf 'container=%s\n' "$status" > "$out/status.txt"
  for item in logs renderers render_summary.md mesa-packages.txt driver.txt initialized-libraries.log ordinary-logs; do
    if [[ -e "$run/$item" ]]; then sudo cp -a "$run/$item" "$out/"; fi
  done
done
