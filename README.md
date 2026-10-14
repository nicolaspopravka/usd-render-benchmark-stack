# USD Render Benchmark Stack

This repository builds the container images used to run the
[USD Render Benchmark](https://github.com/nicolaspopravka/usd-render-benchmark).

The image supplies the software environment. The benchmark branch supplies the
harness, scenes, renderer selection, and output directories. Keeping those
parts separate allows the same image to run different benchmark branches
without rebuilding the image.

This is an independent community project. The images are not ASWF or OpenUSD
certification, and publishing an image does not by itself produce a benchmark
result.

## Repository split

The current setup has three parts:

- [`AcademySoftwareFoundation/aswf-docker`](https://github.com/AcademySoftwareFoundation/aswf-docker)
  builds the underlying VFX Platform and renderer environments.
- This repository composes those environments into images that follow the
  benchmark's run conventions.
- [`nicolaspopravka/usd-render-benchmark`](https://github.com/nicolaspopravka/usd-render-benchmark)
  contains the harness and the branches that preserve individual run results.

A run branch is mounted at a caller-selected directory, which is also the
container's working directory. The default command executes that branch's
`render_script.sh`. Logs and renders remain in the mounted checkout; summary
generation is a separate runner step.

## Images

| Image | Purpose |
| --- | --- |
| `ghcr.io/nicolaspopravka/usd-render-benchmark-stack:<tag>` | The pinned ASWF base, selected repairs, and delegate builds. |
| `ghcr.io/nicolaspopravka/usd-render-benchmark:<tag>` | Thin runnable overlay with `REZ_PACKAGES_PATH=./packages` and default command `bash render_script.sh`. The caller supplies the working directory and run branch. |

Both images carry OCI identity and base-image labels. Recorded results should
retain the image digest and the exact run commit that were observed.

## Build workflows

The manual **Build stack** workflow builds and publishes both images from a
profile JSON. Select the profile path:

```bash
gh workflow run build.yml \
  --repo nicolaspopravka/usd-render-benchmark-stack \
  -f profile=profiles/cy2025.json
```

Commands use the repository's default branch, `main`. To use another recipe
branch, add `--ref <recipe-branch>`.

A failed build fails the workflow. Each push is checked against the published
tag. The build log prints pinned `Pristine:` and `Runnable:` references when
both images have been published. Set `RUNNABLE_IMAGE` to the printed runnable
reference for the commands below.

## Build framework

[Profiles](profiles/) select the pinned ASWF base, repairs and delegates.
OpenUSD and MoonRay versions come from the base; Cycles versions and options
come from the profile. The [composer](tools/build.py) builds the selected stack
and its runnable overlay. The implementation is in [repairs](repairs/),
[delegates](delegates/) and [build support](build-support/).

| Profile | ASWF base | Cycles | Cycles OSL / OpenVDB |
| --- | --- | --- | --- |
| [CY2023](profiles/cy2023.json) | `ci-moonray:2023.5` | v4.0.2 | OFF / OFF |
| [CY2024](profiles/cy2024.json) | `ci-moonray:2024.9` | v4.3.0 | OFF / OFF |
| [CY2025](profiles/cy2025.json) | `ci-moonray:2025.8` | v5.0.0 | ON / ON |

### Repairs

These profiles select the following repairs. Upstream changes do not alter
the pinned images; remove a repair after checking the replacement base.

| Repair | Purpose | Internal tracking | Upstream tracking |
| --- | --- | --- | --- |
| [time](repairs/time.pristine) | GNU time for measurements | — | [ASWF PR #468](https://github.com/AcademySoftwareFoundation/aswf-docker/pull/468) |
| [rez](repairs/rez.pristine) | Rez package environment | — | [ASWF PR #467](https://github.com/AcademySoftwareFoundation/aswf-docker/pull/467) |
| [pythonpath](repairs/pythonpath.runnable) | OpenUSD Python module lookup | — | — |
| [git-lfs](repairs/git-lfs.pristine) | OpenMoonRay source checkout | — | — |
| [epoxy](repairs/epoxy.pristine) | Cycles development dependency | — | — |
| [usd-cmake](repairs/usd-cmake.pristine) | OpenUSD dependency exports | [#34](https://github.com/nicolaspopravka/usd-render-benchmark/issues/34) | [ASWF #480](https://github.com/AcademySoftwareFoundation/aswf-docker/issues/480), [PR #490](https://github.com/AcademySoftwareFoundation/aswf-docker/pull/490) |
| [ispc](repairs/ispc.pristine) | Working ISPC compiler | — | [ASWF #469](https://github.com/AcademySoftwareFoundation/aswf-docker/issues/469), [PR #473](https://github.com/AcademySoftwareFoundation/aswf-docker/pull/473) |
| [osl-shader-includes](repairs/osl-shader-includes.pristine) | Installed OSL shader headers | — | [ASWF PR #487](https://github.com/AcademySoftwareFoundation/aswf-docker/pull/487) |

### Cycles feature overrides

| Setting | Years | Reason | Tracking |
| --- | --- | --- | --- |
| `WITH_CYCLES_OSL=OFF` | CY2023–CY2024 | OSL compiler cannot start with the supplied LLVM runtime | [#54](https://github.com/nicolaspopravka/usd-render-benchmark/issues/54), [ASWF #469](https://github.com/AcademySoftwareFoundation/aswf-docker/issues/469) |
| `WITH_CYCLES_OPENVDB=OFF` | CY2023–CY2024 | Older Cycles tags expect OpenVDB delayed-loading APIs | [#56](https://github.com/nicolaspopravka/usd-render-benchmark/issues/56), [ASWF #488](https://github.com/AcademySoftwareFoundation/aswf-docker/issues/488) |

These settings disable Cycles OSL shading and volume support for those years.

## Run a benchmark branch

Clone a run branch with its submodules:

```bash
git clone \
  --branch demo/run3 \
  --single-branch \
  --recurse-submodules \
  https://github.com/nicolaspopravka/usd-render-benchmark.git \
  run-branch
```

Mount it into a runnable image:

```bash
docker run --rm \
  -v "$PWD/run-branch:/benchmark" \
  -w /benchmark \
  "$RUNNABLE_IMAGE"
```

Display, GPU, and headless-rendering requirements remain properties of the
selected environment and runner. The command above shows the mount contract;
it is not a guarantee that every renderer can run on every Docker host.

## Headless demo

The `run-demo` workflow exercises the same model on a GitHub-hosted runner. It
clones a benchmark branch, initializes its submodules, mounts it into the
selected image, runs the harness with Mesa and Xvfb, generates the summary,
and uploads the resulting files.

Use the `Runnable:` reference printed by the build:

```bash
gh workflow run run-demo.yml \
  --repo nicolaspopravka/usd-render-benchmark-stack \
  -f run_branch=demo/run3 \
  -f runnable_image="$RUNNABLE_IMAGE"
```

Download the `run-output` artifact and inspect its logs, images and summary.
The harness continues after a renderer fails, so workflow success alone does
not establish render success. Embree is not included in these profiles.

## Optional host C++ conformance

Profiles enable `"cxx_conformance": true` explicitly; omission defaults to off. Enabled
mode selects GCC toolset 11/C++17 for CY2023–CY2025, or toolset 14/C++20 for
CY2026–CY2027. The shared launcher activates the settings in each delegate
build shell. These are build settings; they do not establish conformance of
inherited ASWF components or runtime/render conformance.
