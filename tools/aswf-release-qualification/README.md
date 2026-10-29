# October 27 ASWF qualification

Run these checks from the repository containing this tooling. `images.tsv` records the five
released manifest digests resolved on October 29. They are not config-blob IDs.
Use a new output directory for each attempt; old benchmark outputs are untouched.

## Stock OpenUSD consumer

```bash
bash tools/aswf-release-qualification/run-consumer.sh \
  2025 "$PWD/docs/evidence/aswf-october27-qualification/consumer-cy2025"
```

Repeat for 2023, 2024, 2026 and 2027 as capacity allows. Pull/start failures stop
the host runner. The container hides `/opt/conan_home`, captures unchanged USD
exports, calls `find_package(pxr CONFIG REQUIRED)` twice, builds the linked
consumer and requires `CONSUMER_PASS`. No dependency stubs, exports or preload
workarounds are supplied. A runtime failure is retained even if compilation works.

For the separate CY2025 MoonRay check, mount an unchanged recursive checkout of
OpenMoonRay v2026.29.1 (`d96c6e30a8c280d4b5eb3bafa5e54efc445d7ea8`) read-only
at `/source`, this directory at `/probe`, and a new writable results directory at
`/results`. Invoke `bash /probe/moonray.sh /source /results/moonray` in the
CY2025 pinned image. This only configures; it neither builds MoonRay nor repairs
installed exports. Preserve the superproject and recursive submodule refs.

## Composed software-GL comparison

```bash
bash tools/aswf-release-qualification/run-render.sh \
  2025 /path/to/stack-recipe /path/to/demo-run3 "$PWD/results-cy2025"
```

The recipe must be the clean reviewed stack commit
`f99bfd5959a529a7bbbc385fc53e0314bf9f4459`; the benchmark must be clean
`0649e883134579fa1ad7a46daa072cfafac2cef0`, with its Teapot assets initialized.
Only the selected profile's ASWF base changes. Existing source selections,
C++ settings, features and repairs are retained; in particular this composed
check does not establish that the USD CMake repair can be removed.
Builds stay local: no registry login or push. Full delegate builds need more
capacity than the current 4 GB Docker host. Inspect CY2025 before selecting
the CY2024 or CY2026 follow-ups.

The render client uses `LIBGL_ALWAYS_SOFTWARE=1` and
`LIBGL_DRIVERS_PATH=/usr/local/lib/dri`; Xvfb retains its normal environment.
There is no distro LLVM prepend, preload or shader-cache override. Each GL/Cycles
attempt records its own exit status, fresh JPEG and compressed loader trace.
Require the expected plugin in logs, successful process status, inspected images
and a compatible loaded LLVM before accepting a render. Material appearance is
reported separately from recovery of the LLVM abort.

## Native Linux workflow, awaiting authorization

`check.yml` is an inactive workflow prepared for a diagnostic branch. After
approval, copy it to `.github/workflows/qualify-aswf-october27.yml` on a stack diagnostic branch
containing only this tooling and that workflow. Dispatch `phase=consumer` first:
five pinned-image jobs, at most two concurrent, 45 minutes per job, with the
additional unchanged MoonRay configure on CY2025. Review the artifacts before
dispatching `phase=render,year=2025` (one 120-minute job). Later render years
require deliberate selection. Permissions are contents:read, with no publishing
or registry credentials. Do not push the private plans or evidence with it.
