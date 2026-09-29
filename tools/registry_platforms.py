#!/usr/bin/env python3
"""Print the per-platform manifest digests of a registry image, one per line.

Used by promote-release-tag to check that a promoted release tag serves the
same image content as the tag it was promoted from.

The index digest deliberately cannot be compared: `docker buildx imagetools
create` re-serialises the manifest list, so the index digest changes on a tag
copy even when every platform manifest is identical, and a single-platform
build is promoted from a plain manifest into a list of one. The per-platform
manifest set is the invariant that actually holds.

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
    try:
        raw = subprocess.run(
            ["docker", "buildx", "imagetools", "inspect", reference, "--raw"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        manifest = json.loads(raw)
    except (subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"ERROR: could not read {reference}: {error}", file=sys.stderr)
        return 1

    entries = manifest.get("manifests")
    if entries:
        for entry in entries:
            platform = entry.get("platform", {})
            name = f"{platform.get('os', '?')}/{platform.get('architecture', '?')}"
            if platform.get("variant"):
                name += "/" + platform["variant"]
            print(f"{name} {entry['digest']}")
    else:
        # A plain manifest: identify it by its config digest, which is stable
        # across a re-serialisation of a list containing just this one.
        config = manifest.get("config", {}).get("digest", "")
        if not config:
            print(f"ERROR: {reference} has no manifest list and no config digest",
                  file=sys.stderr)
            return 1
        print(f"single {config}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
