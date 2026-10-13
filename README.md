# USD Render Benchmark Stack

This first iteration resolves CY2023–CY2027 profiles and builds local pristine
and runnable images. Profiles use JSON so the entry point needs only Python's
standard library. Edit a profile's `base_image` to a raw ASWF image reference
with a SHA-256 digest before building. CY2025 has a pinned raw ASWF base; the other years await selection.
Historical prepared benchmark images are not defaults.

    python3 tools/build.py resolve --year 2025
    python3 tools/build.py build --year 2025

Build logs and a receipt go under `.build/<attempt>/`. Builds use unique local
tags and never push. Runnable uses the pristine image's exact local image ID;
this ID is not a registry manifest digest. Mount the benchmark checkout at
`/usr/local/usd-render-benchmark` when running the image.

Storm is inherited. Embree, Cycles and MoonRay are explicitly excluded until
builder integration. Repairs and candidate source changes are also pending;
requests for these fail before Docker starts. `--variant candidate` currently
resolves to the same inputs as released and reports that fact.

CI workflows and optional delegate builders will be added in later iterations.
No runtime or render acceptance is claimed by a successful build.
