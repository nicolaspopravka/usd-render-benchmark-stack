# usd-render-benchmark-stack

Image composition for the USD Render Benchmark's stacks. The run
*content* (a run branch: harness + scenes on a git branch) is kept separate
from the image — the image is a reusable environment, and a run branch is
mounted into it at run time.

## Images

| Image | Build | What it is |
|---|---|---|
| `ghcr.io/nicolaspopravka/usd-render-benchmark-stack:<year>` | `build-pristine` | A trivial retag of the ASWF base (`base_image` input), e.g. `aswf/ci-vfxall:2025`. The byte-pristine environment. |
| `ghcr.io/nicolaspopravka/usd-render-benchmark:<year>` | `build-runnable` | `FROM` the pristine + run conventions (workdir, `render_script.sh` entrypoint, rez packages path). A thin environment overlay — **no run content baked in**. |

## Run by mounting a branch

The runnable image does not contain a run branch. Point it at one with a bind
mount so its `render_script.sh` runs from the mounted checkout:

```bash
docker run --rm \
  -v /path/to/run-branch:/usr/local/usd-render-benchmark \
  ghcr.io/nicolaspopravka/usd-render-benchmark:2025
```

The entrypoint is `bash render_script.sh` with workdir
`/usr/local/usd-render-benchmark`, so the mounted branch's harness runs and
writes its output (`logs/`, `renderers/`, `render_summary.md`) back into that
checkout.

## Demo: `run-demo` workflow

`run-demo.yml` demonstrates this on a free GitHub runner: it clones a run
branch, mounts it into the published runnable image, and runs the harness
headlessly (software GL added inside the running container — no image rebuild).
It produces Teapot renders when run against the `test/cy2025` run branch.

Dispatch:

```bash
gh workflow run run-demo --repo nicolaspopravka/usd-render-benchmark-stack \
  -f run_branch=test/cy2025 \
  -f runnable_image=ghcr.io/nicolaspopravka/usd-render-benchmark:2025
```

## Workflow inputs

- `build-pristine`: `base_image` (required) — the ASWF base to retag; the year
  is derived from it.
- `build-runnable`: `pristine_image` (required) — the pristine image to layer on.
- `run-demo`: `run_branch` (default `main`), `runnable_image` (required).

## Topology

- `AcademySoftwareFoundation/aswf-docker`: the ASWF VFX image build, from which
  delegates and the pristine base are sourced.
- `nicolaspopravka/usd-render-benchmark-stack` (this repo): image composition.
- `nicolaspopravka/usd-render-benchmark`: benchmark harness and run branches.
