#!/usr/bin/env bash
set -euo pipefail
profile=${1:?profile path}
out=${2:?fresh output directory}
test ! -e "$out"
mkdir -p "$out"
out=$(cd "$out" && pwd)
probe=$(cd "$(dirname "$0")" && pwd)
year=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["year"])' "$profile")
base=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["base_image"])' "$profile")
printf 'PROFILE=%s\nBASE=%s\n' "$profile" "$base" | tee "$out/build.log"
docker pull "$base" 2>&1 | tee -a "$out/build.log"
docker run --rm --entrypoint /bin/bash \
    -v "$probe:/probe:ro" -v "$out:/results" \
    "$base" /probe/check.sh stock "$year" /results/stock \
    2>&1 | tee "$out/stock-container.log"
test -s "$out/stock/status.txt"
export BUILDKIT_PROGRESS=plain
python3 tools/build.py "$profile" 2>&1 | tee -a "$out/build.log"
failed=0
for mode in pristine runnable; do
    if [ "$mode" = pristine ]; then label=Pristine; else label=Runnable; fi
    image=$(sed -n "s/^$label: //p" "$out/build.log")
    test -n "$image"
    docker image inspect "$image" --format 'ID={{.Id}} Revision={{index .Config.Labels "org.opencontainers.image.revision"}} Base={{index .Config.Labels "org.opencontainers.image.base.name"}}' > "$out/$mode-image.txt"
    if docker run --rm --entrypoint /bin/bash \
        -v "$probe:/probe:ro" -v "$out:/results" \
        "$image" /probe/check.sh "$mode" "$year" "/results/$mode" \
        2>&1 | tee "$out/$mode-container.log"; then
        printf '%s=0\n' "$mode" | tee -a "$out/status.txt"
    else
        printf '%s=%s\n' "$mode" "$?" | tee -a "$out/status.txt"
        failed=1
    fi
done
exit "$failed"
