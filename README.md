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

Profiles pin the latest published official ci-moonray base for each year.
Candidate changes live on recipe branches. CY2023–CY2025 profiles select two builders:

```json
"delegates": {
  "moonray": {},
  "cycles": {"CYCLES_TAG": "v5.0.0"}
}
```

Omission builds no additional delegates. MoonRay follows `ASWF_MOONRAY_VERSION`. Both delegate builders run in the same image stage, in profile order.
MoonRay installs directly into `/usr/local`; Cycles installs into `/opt/cycles`.
Neither builder requires the other; parallel execution is deferred. Selected
build failures stop image publication. Builds remain unvalidated against the selected bases.

Profiles enable `cxx_conformance` explicitly; omission defaults to off. Enabled
settings select GCC toolset 11/C++17 for CY2023–2025 and toolset 14/C++20 for
CY2026–2027. The shared build launcher activates these settings in each independent build
shell; existing builders pass `VFX_CXX_STANDARD` to CMake. A missing toolset fails the build. Settings
do not establish conformance of inherited ASWF software.

Profiles select temporary repairs by basename, for example
`"repairs": ["time", "rez", "pythonpath"]`. The builder appends matching
`repairs/<name>.pristine` and `.runnable` fragments in that order and sends
the result to Docker through stdin. Omission applies none; unknown names fail.
CY2023–CY2025 select time, Rez, pythonpath and Git LFS.
Remove selections when the pinned ASWF release supplies the prerequisite.

Cycles selections are v4.0.2, v4.3.0 and v5.0.0 for CY2023–CY2025. OSL and OpenVDB retain their ON defaults; no annual overrides.

Embree and CY2026–CY2027 profiles are deferred.

Both builders load `build-support/aswf_usd_deps.cmake` through
`CMAKE_PROJECT_INCLUDE`. This shared consumer support resolves OpenUSD's
library dependency targets; it does not rewrite the base's CMake files and
needs no repair selection in the profiles.
