#!/bin/bash
set -euo pipefail
mkdir results
python3 tools/build.py profiles/cy2026.json 2>&1 | tee results/build.log
candidate=$(sed -n 's/^Runnable: //p' results/build.log | tail -1)
control=ghcr.io/nicolaspopravka/usd-render-benchmark:2026@sha256:6d35b1c7db7e04387b6999f0e688d8612f33fd6b6f3e1e0aaa202fe2f65dd4d5
docker pull "$control"
for kind in published candidate; do
  image="$control"
  if [[ "$kind" = candidate ]]; then image="$candidate"; fi
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
  docker run --rm --platform linux/amd64     --mount "type=bind,source=$run,target=/benchmark"     --env REZ_PACKAGES_PATH=/benchmark/packages     --workdir /benchmark --entrypoint bash "$image" -c '
      set -e
      dnf install -y --disablerepo=cuda mesa-dri-drivers
      rpm -qa | sort | grep -E "^(mesa|llvm|libglvnd)" > mesa-packages.txt
      LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a bash render_script.sh
      python3 generate_render_summary.py --system-specs "Software-rendered Docker demo"
    ' 2>&1 | tee "$out/container.log"
  status=${PIPESTATUS[0]}
  set -e
  printf 'container=%s\n' "$status" > "$out/status.txt"
  for item in logs renderers render_summary.md mesa-packages.txt; do
    if [[ -e "$run/$item" ]]; then sudo cp -a "$run/$item" "$out/"; fi
  done
done
