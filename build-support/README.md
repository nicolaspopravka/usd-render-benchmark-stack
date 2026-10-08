# Annual host C++ settings

The image/workflow environment requires `VFX_PLATFORM_YEAR`, independently of
its output tag. CY2023–CY2025 select GCC 11.2.x and C++17; CY2026–CY2027 select
GCC 14.2.x and C++20. `vfx-cxx.sh` activates the existing `/opt/rh` toolset and
exports `CC`, `CXX` and `VFX_CXX_STANDARD`. It does not install a compiler.
The delegate build scripts do not source this helper.

The scripts retain direct Git and CMake commands. Their new configuration is
limited to CMake's standard, required-standard, extensions and compile-database
options, plus verbose build output. They retain their existing source refs,
feature choices and dependency locators. No cloned delegate source is changed.
Compiler selection, evidence collection and plugin checks are outside them.

`validate-build.sh` runs the build script as one command, checks its effective
host C++ compile commands afterwards, then checks unresolved symbols and plugin
loading. A project can override a requested CMake setting: configure success or
a completed build alone does not establish compliance. Such an override fails
acceptance; it is not repaired by rewriting source or weakening the settings.
CUDA/ISPC/C commands are outside the host C++ check. CUDA host selection remains
separate and explicit.

The outer Docker step removes build directories only after validation. hdEmbree
uses `/opt/build-hdembree` by default (`HDEMBREE_BUILD_ROOT` can override it).
Standalone script callers must select their compiler/standard environment and
clean their build directory themselves. The existing external hdEmbree consumer
is repository-specific integration, not an upstream standalone build recipe.

Requested settings, compiler/ABI results, source revisions, build output, CMake
cache and compile database are saved under
`/usr/local/share/usd-render-benchmark/build-evidence/<delegate>`. Failed attempts
remain nonzero. The external validator saves partial configuration and prints
selected cache settings and available effective-command diagnostics on failure;
plain Docker logs carry the command/output/status because failed layers are not
published image artifacts. Compiler activation errors fail in the outer step.
These checks do not test rendering or certify inherited upstream components.
Inspect upstream only to explain an observed build failure; do not replace it.

In the combined recipe, `moonray_toolset` may be empty or match the annual
compiler. A conflict fails before the existing provisioning fixer runs. The
existing dependency fixers are retained, not expanded by this change.

Build-command references:
- [Cycles BUILDING.md](https://projects.blender.org/blender/cycles/src/branch/main/BUILDING.md)
- [MoonRay container build](https://docs.openmoonray.org/getting-started/installation/building-moonray/rocky9_container_build/)
- [CMake CXX_STANDARD](https://cmake.org/cmake/help/latest/variable/CMAKE_CXX_STANDARD.html)

Run local fixtures with `python3 -m unittest discover -s tests -v`. They use
small local CMake projects, fixture GCC identities and stub Linux loading;
no delegates are downloaded and no images are built. `VFX_EVIDENCE_DIR` and
`VFX_TOOLSET_ROOT` allow disposable fixture locations. They do not establish
real Linux SDK, delegate, GPU or rendering acceptance.
