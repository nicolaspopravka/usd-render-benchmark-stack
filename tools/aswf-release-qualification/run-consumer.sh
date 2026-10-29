#!/usr/bin/env bash
set -euo pipefail
year=${1:?year}
out=${2:?fresh host output directory}
probe=$(cd "$(dirname "$0")" && pwd)
image=$(awk -F '\t' -v year="$year" '$1 == year {print $2}' "$probe/images.tsv")
test -n "$image" || { echo "Unknown year: $year" >&2; exit 2; }
test ! -e "$out" || { echo 'Use a fresh output directory' >&2; exit 2; }
mkdir -p "$out"
out=$(cd "$out" && pwd)
printf '%s\n' "$image" > "$out/image.txt"
# Pull/start errors stop here; they are never reported as consumer failures.
docker pull "$image" 2>&1 | tee "$out/pull.log"
docker image inspect "$image" --format 'ID={{.Id}} Digests={{json .RepoDigests}}' >> "$out/image.txt"
docker run --rm --platform linux/amd64 --entrypoint /bin/bash \
    -v "$probe:/probe:ro" -v "$out:/results" \
    "$image" /probe/consumer.sh /results 2>&1 | tee "$out/container.log"
