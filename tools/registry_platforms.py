#!/usr/bin/env python3
"""Print the manifest digests a registry image is served from, one per line.

Used by promote-release-tag to check that a promoted release tag serves the
same image content as the tag it was promoted from.

Only the digests are printed, and deliberately no platform labels and no
index digest, because a promote changes the *shape* of what a tag points at:
`docker buildx imagetools create` re-serialises the manifest list, so the index
digest changes on a tag copy even when every manifest is identical, and a
single-platform build is promoted from a plain manifest into a list of one. The
set of manifest digests is the invariant that survives that, and since a
manifest digest is platform-specific, a promote that landed the wrong platform
still fails the comparison.

Note a plain manifest cannot report its own digest from `--raw`, which is
config data only; it is fetched with `imagetools inspect --format` instead.
Reporting a plain manifest by its *config* digest, as an earlier version of this
script did, compares a different kind of identifier to the one a promoted list
reports and never matches.

    registry_platforms.py <image-reference>

Exits non-zero if the reference cannot be read, so a caller comparing two
outputs cannot mistake "both empty" for a match.
"""

import json
import subprocess
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    reference = sys.argv[1]
    def inspect(*extra: str) -> str:
        return subprocess.run(
            ["docker", "buildx", "imagetools", "inspect", reference, *extra],
            capture_output=True,
            text=True,
            check=True,
        ).stdout

    try:
        raw = inspect("--raw")
        manifest = json.loads(raw)
    except (subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"ERROR: could not read {reference}: {error}", file=sys.stderr)
        return 1

    entries = manifest.get("manifests")
    if entries:
        for entry in entries:
            print(entry["digest"])
        return 0

    # A plain manifest. --raw carries config data, not the manifest's own
    # digest, so ask the registry for that separately and take the last field:
    # the human-readable output is "<label>  sha256:...", so the digest is last.
    try:
        digest = inspect("--format", "{{.Manifest.Digest}}").split()[-1]
    except (subprocess.CalledProcessError, IndexError) as error:
        print(f"ERROR: could not resolve {reference}: {error}", file=sys.stderr)
        return 1
    if not digest.startswith("sha256:"):
        print(f"ERROR: unexpected digest {digest!r} for {reference}", file=sys.stderr)
        return 1
    print(digest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
