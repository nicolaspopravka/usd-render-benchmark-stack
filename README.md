# USD Render Benchmark Stack

Build pristine and runnable images on GitHub Actions. Run **Build stack**,
select the recipe branch, and provide a profile JSON path
(default: `profiles/cy2025.json`).

The profile supplies the year and base image digest. Each build uses distinct
tags on the GitHub runner, prints Docker progress and stops on failure. It does not push images
or write receipts, logs or metadata files. Both images carry OCI identity labels.

Mount a benchmark checkout and select its working directory with
`docker run --workdir`. The runnable image defaults to `bash render_script.sh`
and sets `REZ_PACKAGES_PATH=./packages`.

Candidate changes live on recipe branches. Delegate builders and repairs
will be added when implemented. Successful builds do not establish render success.
