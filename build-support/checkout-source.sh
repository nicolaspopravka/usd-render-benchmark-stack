#!/usr/bin/env bash
# Resolve a tag/branch or a full commit ID, and print the revision actually built.
set -euo pipefail

repository="${1:?repository required}"
ref="${2:?source ref required}"
destination="${3:?destination required}"

if [ -e "$destination" ]; then
    echo "ERROR: source destination already exists: $destination" >&2
    exit 1
fi
git init "$destination"
git -C "$destination" remote add origin "$repository"
git -C "$destination" fetch --depth 1 origin "$ref"
git -C "$destination" checkout --detach FETCH_HEAD
revision=$(git -C "$destination" rev-parse HEAD)
if [[ "$ref" =~ ^[0-9a-f]{40}$ ]] && [ "$revision" != "$ref" ]; then
    echo "ERROR: source revision differs from requested commit: $ref / $revision" >&2
    exit 1
fi
printf 'Source: %s %s -> %s\n' "$repository" "$ref" "$revision"
