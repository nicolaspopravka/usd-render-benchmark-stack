# Annual host C++ build settings

Delegate builds require `VFX_PLATFORM_YEAR`, independently of the output tag.
CY2023–CY2025 select GCC 11.2.x and C++17; CY2026–CY2027 select GCC 14.2.x
and C++20. All use the new libstdc++ ABI. The helper activates the existing
toolset under `/opt/rh`; it does not install or substitute a compiler.

For the combined recipe, `moonray_toolset` may be empty or name the selected
annual toolset. A conflicting override fails before the existing provisioning
fixer runs; it is not silently replaced with the annual compiler. CUDA host
selection remains explicit and separate from the host C++ checks.

The builder passes supported CMake options and checks generated host C++
commands before compilation. A source project that overrides the requested
settings stops the build. Cloned delegate sources remain unmodified.
CUDA device compilation and its host compiler are recorded separately from
the host C++ SDK settings; they are not rewritten by this helper.

Configure, compile/link, install and plugin-loading failures remain nonzero.
Requested settings, compiler/ABI results, source commits, CMake cache and
compile commands are retained under
`/usr/local/share/usd-render-benchmark/build-evidence/<delegate>` in successful
images. Plain Docker build logs retain phase commands, statuses, effective
settings and diagnostics for failed attempts. Inspect upstream components only
to explain a failure; do not replace them or weaken the annual settings.

After installation the builder checks unresolved symbols and loads the
delegate plugin. This does not test rendering or certify the upstream image.
The runnable overlay inherits the built artifacts and evidence unchanged.

Run local fixtures with `python3 -m unittest discover -s tests -v`. They use
small CMake projects and stubbed commands, without downloading delegates or
building images. `VFX_EVIDENCE_DIR` and `VFX_TOOLSET_ROOT` allow disposable
fixture locations; alternate toolset roots still undergo compiler/ABI checks.
