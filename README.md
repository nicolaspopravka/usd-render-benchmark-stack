# USD Render Benchmark Stack

Build pristine and runnable images on GitHub Actions. Run **Build stack**,
select the recipe branch, and provide a profile JSON path
(default: `profiles/cy2025.json`).

The profile supplies the year and base image digest. Each build uses distinct
tags on the GitHub runner, prints Docker progress and stops on failure. The build workflow publishes both images to GHCR. Run the separate **run-demo**
workflow with `run_branch=demo/run1` and the runnable digest. The existing demo
uploads render outputs, logs and its summary.
Builds do not write receipts or metadata files. Both images carry OCI identity labels.

Mount a benchmark checkout and select its working directory with
`docker run --workdir`. The runnable image defaults to `bash render_script.sh`
and sets `REZ_PACKAGES_PATH=./packages`.

Candidate changes live on recipe branches. CY2026 selects all three builders:

```json
"delegates": {
  "embree": {},
  "moonray": {"MOONRAY_TAG": "v2026.29.1"},
  "cycles": {"CYCLES_TAG": "v5.0.0"}
}
```

Omission builds no additional delegates. Embree's OpenUSD source tag comes from
`ASWF_OPENUSD_VERSION` in the base. Each delegate builds from the same prepared
base and stages its installation with `DESTDIR`; the final pristine image copies
those installations. Delegate builds do not depend on one another. Selected
build failures stop image publication. CMake/base repairs are deferred; this
profile is not yet expected to complete successfully.

Profiles enable `cxx_conformance` explicitly; omission defaults to off. Enabled
settings select GCC toolset 11/C++17 for CY2023–2025 and toolset 14/C++20 for
CY2026–2027. Builders must source `build-support/vfx-cxx.sh` in their build shell
and pass `VFX_CXX_STANDARD` to CMake. A missing toolset fails the build. Settings
do not establish conformance of inherited ASWF software.

Profiles select temporary repairs by basename, for example
`"repairs": ["time", "rez", "pythonpath"]`. The builder appends matching
`repairs/<name>.pristine` and `.runnable` fragments in that order and sends
the result to Docker through stdin. Omission applies none; unknown names fail.
CY2023–2026 select time, Rez and pythonpath; CY2027 selects only Rez.
Remove selections when the pinned ASWF release supplies the prerequisite.
