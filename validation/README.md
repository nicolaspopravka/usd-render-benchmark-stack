# Annual host C++ build-only checks

This experimental branch validates CY2023–CY2027 without publishing images.
`annual-cxx-build-only.yml` is manual; its push trigger runs fixtures only.
The separate workflow leaves the existing publication workflows unchanged.
It checks out frozen PR recipe commits and their unchanged bases, rather than
building the validation branch as a renderer recipe.

`annual-inputs.json` fixes base digests, source commits, feature choices and
recipe commits. Each of fifteen pairs builds off, then its annual profile.
A failed off build also runs the unchanged recipe against identical inputs.
Only one pair runs at a time, ordered Embree, Cycles, MoonRay and ascending year.
Every build has a 45-minute limit; resource/time failures remain findings.
A failed build does not stop the remaining pairs. Cancelling the workflow does.

Embree uses stock annual `ci-vfxall` bases and OpenUSD source tags matching the
annual recipes. Cycles uses the established `.2` prepared inputs, with OSL and
OpenVDB off in CY2023/CY2024. MoonRay uses prepared inputs and the existing
GCC 12 override in CY2026/CY2027; enabled conformance is expected to reject that
conflict. These inputs remain the same between off and on. Prepared images can
already contain other delegates, but only the selected delegate is rebuilt.
No components are replaced, renderer source patches added, or upstream
compliance inventory performed. Existing fork refs are used where established
recipes use them; the experiment adds no patches to those sources.

Source refs are checked against their frozen resolved commits before and after
each attempt. Successful builds also require that commit in the build log.
A ref that moves is an input finding and is not silently repinned. Logs include
submodule/build output produced by the established commands. The GNU dialect
and effective-standard/ABI checks are those of the reviewed PRs.

A clean task-specific Docker config avoids inherited registry credentials; all input images are public. The push checks also verify anonymous registry metadata access. The runner's built-in BuildKit uses cache-only output and exports/pushes no image. The input manifest is retained before setup, including when a build cannot start. Each pair uploads
inputs, commands, status, elapsed time and complete logs, including failed
builds and baseline controls. The final artifact and job summary compare all
30 attempts. Missing artifacts remain explicitly not recorded. Automatic
stage classification is provisional; compare actual diagnostics before calling
an off failure a regression or an inherited incompatibility.

Use public GitHub-hosted Ubuntu runners only; do not select larger runners,
paid providers, or start runtime/render checks. Review build findings separately
from whole-image compliance and runtime acceptance.

Local checks: `python3 -m unittest discover -s validation -p 'test_*.py' -v`.
These fixture tests validate orchestration and evidence handling, not renderer
compatibility. Dispatch `annual-cxx-build-only.yml` with this experimental ref;
never substitute a publication workflow.

MoonRay GCC14 follow-up: `moonray-gcc14-build-only.yml` runs enabled CY2026/CY2027 only, using `moonray-gcc14-inputs.json`. The sole build-input change from the original comparison is MOONRAY_TOOLSET=gcc-toolset-14. Original GCC12 off builds are retained as comparison evidence in run37994841643. No recipe/source/base change or image export.
