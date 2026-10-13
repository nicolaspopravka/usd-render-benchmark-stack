# USD Render Benchmark Stack

This first iteration resolves CY2023–CY2027 profiles and builds local pristine
and runnable images. Profiles use JSON so the entry point needs only Python's
standard library. Edit a profile's `base_image` to a raw ASWF image reference
with a SHA-256 digest before building. CY2025 has a pinned raw ASWF base; the other years await selection.
Historical prepared benchmark images are not defaults.

    python3 tools/build.py resolve profiles/cy2025.json
    python3 tools/build.py build profiles/cy2025.json

Build logs and a receipt go under `.build/<attempt>/`. Builds use unique local
tags and never push. Runnable uses the unique local pristine tag, verified against its recorded
image ID before and after building. This ID is not a registry manifest digest. Mount the benchmark checkout at a caller-selected directory and set that
directory with `docker run --workdir` when running the image.

Storm is inherited. Embree, Cycles and MoonRay are explicitly excluded until
builder integration. Repair execution is also pending; requests for repairs
fail before Docker starts.

Main profiles select released sources. Candidate branches change the relevant
source pins or build code and use the same profile-file command. For a matched
comparison, keep the base, settings and repairs identical. The recipe commit
in the receipt and OCI labels identifies each build; builds never merge branches.

CI workflows and optional delegate builders will be added in later iterations.
No runtime or render acceptance is claimed by a successful build.

Both images carry OCI title, source, version, creation time, recipe revision
and immediate base name labels. The receipt retains exact base and image IDs.

OCI version is the profile year (for example `2025`). Base references are fully
qualified. Pristine records the ASWF manifest digest; runnable leaves base.digest
empty because its local parent has no registry manifest digest. Local image IDs
remain in receipts. The base's nonstandard `org.opencontainers.image.name` label
is inherited: Dockerfile LABEL cannot remove an inherited key. These are image
configuration labels; this local build does not add manifest/index annotations.
