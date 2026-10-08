# Optional annual C++ conformance

`cxx_conformance` (workflow input) / `CXX_CONFORMANCE` (Docker build arg) defaults
to `off`. With it off, the image retains its existing compiler choices, CUDA
host selection and upstream configuration defaults; no compiler or command
verification runs. Ordinary build examples need no new input.

Select `2023`, `2024` or `2025` to check C++17/GCC 11.2.x, or `2026`/`2027` for
C++20/GCC 14.2.x. All selected profiles require the new libstdc++ ABI. This is
an experimental check of our host C++ build settings, not whole-image compliance.
The existing annual toolset must be available; this option installs no compiler
and replaces no supplied component. A conflicting `moonray_toolset` fails only
when conformance is selected. The existing `gcc-toolset-12` recipe remains
available with conformance off. CUDA host selection is kept separate.

```bash
gh workflow run build-pristine.yml \
  --repo nicolaspopravka/usd-render-benchmark-stack \
  -f base_image='<prepared base image>' -f image_tag='<experimental output tag>' \
  -f cxx_conformance=2026
```

Set the relevant source-ref inputs too. The existing workflow builds and pushes
images; it is not a read-only test. An empty delegate selection checks no build.

Build scripts retain direct Git/CMake commands. They add CMake standard,
required-standard and compile-database options only when the outer environment
supplies `VFX_CXX_STANDARD`. The image-side helper activates and checks the
selected compiler, then verifies generated host C++ commands after installation.
Equivalent GNU dialects and a matching probed compiler default are accepted.
Overrides, missing evidence and build/check failures remain nonzero findings.
No plugin-loading gate or custom phase logger is included. Docker build logs
carry compiler/profile summaries and failure diagnostics.

Cleanup belongs to the outer Docker step and follows the build and optional
check. Standalone script callers select their environment and clean their build
directories themselves. hdEmbree defaults to `/opt/build-hdembree` (overridable
with `HDEMBREE_BUILD_ROOT`); its existing external consumer keeps C++17 as its
default while accepting an explicitly supplied standard.

Run local fixtures with `python3 -m unittest discover -s tests -v`. They compare
default-off commands with the established recipes, exercise small real CMake
builds and use fixture GCC identities. They do not download renderers or build
images and do not prove annual Linux SDK or rendering acceptance.
