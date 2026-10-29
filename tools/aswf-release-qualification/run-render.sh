#!/usr/bin/env bash
# Build the reviewed recipe locally, then run only Storm/Cycles Teapot checks.
set -euo pipefail
year=${1:?2025, then 2024 or 2026}
recipe=${2:?stack recipe checkout}
benchmark=${3:?demo/run3 checkout with assets}
out=${4:?fresh output directory}
case "$year" in 2024|2025|2026) ;; *) exit 2;; esac
probe=$(cd "$(dirname "$0")" && pwd)
recipe=$(cd "$recipe" && pwd)
benchmark=$(cd "$benchmark" && pwd)
test "$(git -C "$recipe" rev-parse HEAD)" = f99bfd5959a529a7bbbc385fc53e0314bf9f4459
test -z "$(git -C "$recipe" status --porcelain --untracked-files=no)"
test "$(git -C "$benchmark" rev-parse HEAD)" = 0649e883134579fa1ad7a46daa072cfafac2cef0
test -z "$(git -C "$benchmark" status --porcelain --untracked-files=no)"
test -f "$benchmark/assets/full_assets/Teapot/Teapot.usd"
test ! -e "$out"
mkdir -p "$out"
out=$(cd "$out" && pwd)
python3 - "$year" "$recipe" "$probe/images.tsv" "$out/profile.json" <<'PY'
import json
from pathlib import Path
import sys
year, recipe, pins, output = sys.argv[1:]
images = dict(line.split() for line in Path(pins).read_text().splitlines())
profile = json.loads((Path(recipe) / 'profiles' / f'cy{year}.json').read_text())
profile['base_image'] = images[year]
Path(output).write_text(json.dumps(profile, indent=2) + '\n')
PY
export BUILDKIT_PROGRESS=plain
# No --push: both generated images stay on this Docker host.
python3 "$recipe/tools/build.py" "$out/profile.json" 2>&1 | tee "$out/build.log"
image=$(sed -n 's/^Runnable: //p' "$out/build.log")
test -n "$image"
docker image inspect "$image" --format 'ID={{.Id}} Labels={{json .Config.Labels}}' > "$out/image.txt"
docker run --rm --platform linux/amd64 --entrypoint /bin/bash \
    -v "$probe:/probe:ro" -v "$benchmark:/benchmark:ro" -v "$out:/results" \
    -w /benchmark "$image" /probe/render.sh \
    /benchmark/assets/full_assets/Teapot/Teapot.usd /results/render \
    2>&1 | tee "$out/container.log"
