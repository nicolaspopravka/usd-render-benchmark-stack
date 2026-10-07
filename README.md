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
| `ghcr.io/nicolaspopravka/usd-render-benchmark-stack:<tag>` | A selected base with the recipe's dependency fixes, under an explicit output tag. With `cycles_tag` set, the Cycles Hydra delegate is built into `/opt/cycles`. |
| `ghcr.io/nicolaspopravka/usd-render-benchmark:<tag>` | Thin runnable overlay with `REZ_PACKAGES_PATH=./packages` and default command `bash render_script.sh`. The caller supplies the working directory and run branch. |

Image tags are convenient references, not fixed evidence. Recorded results
should retain the image digest and the exact run commit that were observed.

## Build workflows

Both image workflows are manual.

Publish a base stack under an explicit tag:

```bash
gh workflow run build-pristine.yml \
  --repo nicolaspopravka/usd-render-benchmark-stack \
  -f base_image=aswf/ci-vfxall:2027@sha256:... \
  -f image_tag=2027
```

Build the runnable overlay:

```bash
gh workflow run build-runnable.yml \
  --repo nicolaspopravka/usd-render-benchmark-stack \
  -f pristine_image=ghcr.io/nicolaspopravka/usd-render-benchmark-stack:2027@sha256:... \
  -f image_tag=2027
```

Both workflows accept an explicit `image_tag` and never infer it from the input
image reference. The base or pristine image may therefore use a tag, a digest,
or both without changing the requested output tag. The same `image_tag` can be
passed unchanged from the pristine build to the runnable build.

To add Cycles, set `cycles_tag` to the required source ref. The source is
cloned from `cycles_repo` (default: the upstream Blender cycles repo); set
`cycles_repo` when `cycles_tag` names a branch that exists only on a fork,
and record the repo, the ref and the resolved commit — the build log echoes
the exact SHA after the clone. The
`with_cycles_osl` and `with_cycles_openvdb` inputs both default to `ON`.
For the tested CY2023/CY2024 bases with Cycles v4.0.2/v4.3.0, select both
as `OFF`: OSL's compiler lacks its required LLVM runtime libraries
([#54](https://github.com/nicolaspopravka/usd-render-benchmark/issues/54)),
and those older Cycles tags assume OpenVDB delayed-loading APIs absent from
the ASWF packages ([#56](https://github.com/nicolaspopravka/usd-render-benchmark/issues/56)).
These overrides disable Cycles OSL shading and volume support; they are not
source fixes. ASWF's OpenVDB setting is being discussed in
[#488](https://github.com/AcademySoftwareFoundation/aswf-docker/issues/488).

The current Cycles recipe expects a prepared per-year `.2` base when building
the multi-delegate environments. That base supplies the other delegate
(MoonRay or Embree, depending on the year), Rez and GNU
`time`; this Dockerfile does not build or install them. A plain ASWF base is
not interchangeable with that prepared image. Pin the chosen input digest
and record its build recipe. The runnable overlay adds plugin search paths,
the Arras session path, and a Storm-selection workaround for
[#49](https://github.com/nicolaspopravka/usd-render-benchmark/issues/49).

The Build + push steps run with `pipefail`, so a failed build fails the
workflow. The build records the digest it pushed (`--metadata-file`), and a
follow-up step confirms the published tag resolves to that exact digest, so a
missing, wrong, or stale push fails the run. Keep the build log (uploaded as
an artifact) and the image digest with any recorded result.

## Run a benchmark branch

Clone a run branch with its submodules:

```bash
git clone \
  --branch demo/run1 \
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

```bash
gh workflow run run-demo.yml \
  --repo nicolaspopravka/usd-render-benchmark-stack \
  -f run_branch=demo/run1 \
  -f runnable_image="$RUNNABLE_IMAGE"
```

The verified demonstration is
[run 34144139279](https://github.com/nicolaspopravka/usd-render-benchmark-stack/actions/runs/34144139279).
It rendered the Teapot scene with Storm and wrote the image, log, and summary
back into the mounted checkout.

## Current reproduction status

The successful CY2027 demonstration used
`ghcr.io/nicolaspopravka/usd-render-benchmark:2027` at observed digest:

```text
sha256:edc74bf323c3da67a98b9d455b2a52e5d4401a18ef680a2ee80d5b30b6754a2e
```

That image was built from an intermediate repository revision,
[`635e796`](https://github.com/nicolaspopravka/usd-render-benchmark-stack/commit/635e796a564a99a5a9b8e53dafd4d8570337dc32).
The intermediate base image installed Rez and GNU `time`, and its runnable
overlay added Rez to `PATH`.

Current `main` has since gained the delegate build options, dependency fixes
and runnable environment described above. It still relies on prepared bases
for MoonRay, Rez and GNU `time`; the demo is evidence for its recorded image,
not for every image built from today's recipe.

The CY2023/CY2024 build updates were merged in
[PR #14](https://github.com/nicolaspopravka/usd-render-benchmark-stack/pull/14),
including the Python discovery hint and configurable OSL/OpenVDB support.
Full builds and benchmark renders using refreshed ASWF bases are deferred
until new upstream images are released. Merged build scripts do not replace
the pinned images behind the published results.

The demo branch records the result that was actually observed:
[`demo/run1`](https://github.com/nicolaspopravka/usd-render-benchmark/tree/demo/run1).
