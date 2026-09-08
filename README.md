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

A run branch is mounted at `/usr/local/usd-render-benchmark`. The container
executes that branch's `render_script.sh`, and the resulting `logs/`,
`renderers/`, and `render_summary.md` remain in the mounted checkout.

## Images

| Image | Purpose |
| --- | --- |
| `ghcr.io/nicolaspopravka/usd-render-benchmark-stack:<year>` | Base stack selected for a VFX Platform year. The current `Dockerfile.pristine` adds no benchmark files or packages to the selected base image. |
| `ghcr.io/nicolaspopravka/usd-render-benchmark:<year>` | Thin runnable overlay that sets the benchmark work directory, `REZ_PACKAGES_PATH`, and `render_script.sh` entrypoint. It does not contain a run branch. |

The year tags are convenient references, not fixed evidence. Recorded results
should retain the image digest and the exact run commit that were observed.

## Build workflows

Both image workflows are manual.

Build the base stack from an ASWF image:

```bash
gh workflow run build-pristine.yml \
  --repo nicolaspopravka/usd-render-benchmark-stack \
  -f base_image=aswf/ci-vfxall:2027
```

Build the runnable overlay:

```bash
gh workflow run build-runnable.yml \
  --repo nicolaspopravka/usd-render-benchmark-stack \
  -f pristine_image=ghcr.io/nicolaspopravka/usd-render-benchmark-stack:2027
```

`build-pristine` derives the year from the ASWF image name.
`build-runnable` currently expects a tag whose final component is the year.

The Build + push steps run with `pipefail`, so a failed build fails the
workflow. The build records the digest it pushed (`--metadata-file`), and a
follow-up step confirms the published tag resolves to that exact digest; the
derived year is validated too, so a missing, wrong, or stale push fails the
run. Keep the build log (uploaded as an artifact) and the image digest with
any recorded result.

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
  -v "$PWD/run-branch:/usr/local/usd-render-benchmark" \
  ghcr.io/nicolaspopravka/usd-render-benchmark:2027
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
  -f runnable_image=ghcr.io/nicolaspopravka/usd-render-benchmark:2027
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

Those additions are not present in the Dockerfiles on current `main`.
Current `main` therefore documents the intended minimal composition, but it
has not yet reproduced the image used by the successful demo. A new image
should not be described as equivalent until its build, pull, renderer
selection, and output have been checked.

The demo branch records the result that was actually observed:
[`demo/run1`](https://github.com/nicolaspopravka/usd-render-benchmark/tree/demo/run1).
