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

Candidate changes live on recipe branches. Delegate builders and repairs
will be added when implemented. Successful builds do not establish render success.

Runnable supplies Rez, GNU time and the ASWF Python import path needed by the
benchmark. The GitHub demo installs Mesa for software rendering.
