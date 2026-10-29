# Released-base rebuild check

This diagnostic rebuild uses the five maintained profiles from main cd872262,
with October 27 ASWF base pins and no selected usd-cmake repair. CY2023–CY2025
keep their original MoonRay/Cycles versions, feature and C++ settings. CY2026
and CY2027 remain Storm-only ci-vfxall profiles; development PR26 is excluded.

Rez remains needed in ci-moonray (ASWF PR467 installs it in ci-vfxall only).
Python lookup, Git LFS, epoxy development files and CY2025 GL selection retain
their existing purpose. Older time/ISPC/OSL-header repairs were already unselected.

Run from this repository with a fresh output directory:

```bash
bash tools/release-build-check/run.sh profiles/cy2025.json "$PWD/results"
```

The manual build.yml workflow runs all five years on separate native runners,
at most two concurrently, with a 120-minute job limit. Both image stages stay
local to the runner: tools/build.py is called without --push. Advertised image
tags and benchmark outputs are unchanged.

Stock checks capture missing tools and package behavior before building.
Pristine and runnable checks require a no-cache external USD consumer to
configure, build and run. Pristine Rez is checked at its installed path;
runnable checks use the default environment, resolve the benchmark's empty usd
Rez package, list renderer IDs and load the built delegate libraries. The
package fixture is the demo/run1 packages/usd/any/package.py; it supplies no
lookup overrides. No graphics context or render is created. Import/loading
success does not establish render correctness or resolve render-only issues.

Inspect individual stage logs even if a workflow succeeds. A failed first
image build cannot produce the runnable child; preserve that failure without
restoring the removed repair in the same attempt. The workflow uploads logs
and image IDs, excluding generated CMake build trees.
