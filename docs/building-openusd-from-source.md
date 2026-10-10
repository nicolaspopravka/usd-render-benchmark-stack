# Building OpenUSD from source in these images

**Status: probed, not implemented.** No recipe change, no image, no dispatch.
This records why, so the next agent does not repeat the investigation.

## The question

Two upstream PRs cannot reach the benchmark by patching a delegate, because the
images consume OpenUSD **prebuilt** from the ASWF base and this repository has
never built it:

| PR | Change | Files | Merged? |
|---|---|---|---|
| [OpenUSD #4238](https://github.com/PixarAnimationStudios/OpenUSD/pull/4238) | Storm/GL renderer alias resolves to hdStorm | 1 Python file (+23) | OPEN, MERGEABLE, **BLOCKED** |
| [OpenUSD #4176](https://github.com/PixarAnimationStudios/OpenUSD/pull/4176) | HdSt Ptex texel buffer size guard | 4 files (+184 −9) | OPEN, MERGEABLE, **BLOCKED** |

Both are Nicolas's. #4238 is our GH #49; #4176 is our GH #15 / OpenUSD
#4168/#4169 (Moana Island `MemoryError` and `SIGSEGV`).

Adopting either means adding an OpenUSD source-build stage to
`Dockerfile.pristine` — a capability this repository does not have, and one
that would replace the single USD build the images are built around.

## What is already in the image

Checked on `usd-render-benchmark:2026` (the CY2026 runnable, i.e. the plain
Storm-only base with no delegate overlay):

| Dependency | State |
|---|---|
| Boost, TBB, Imath, OpenEXR, OpenColorIO, OpenImageIO | headers **and** CMake configs present |
| OpenSubdiv, Alembic, MaterialX | headers **and** CMake configs present |
| Ptex | `libPtex.so.2.4` + `PtexConfig.cmake` present, **headers absent** |

So the only genuine gap is Ptex's headers. `find_package(Ptex CONFIG)` still
*reports success* — its config calls `set_and_check` on a path layout that does
not fail here — so a build that enables Ptex support fails later at compile
time on the missing headers, not at configure time. That ordering is worth
knowing: the configure looks healthy and the failure arrives hundreds of
targets in.

Ptex is buildable from source. `conan-center-index` carries recipes for 2.4.0
and 2.4.2, and the image ships 2.4, so headers can be provisioned rather than
worked around.

## Why Ptex must be enabled

The ASWF OpenUSD in these images is built **with** Ptex support: `libusd_hdSt.so`
carries a `DT_NEEDED` on `libPtex.so.2.4` and exports ~200 Ptex symbols. A
rebuild with `PXR_ENABLE_PTEX_SUPPORT=OFF` would therefore be a silent
regression, dropping the texture path that #4176 exists to fix, in an image
whose whole purpose is to render those scenes.

That is the sharp edge in this whole question: **#4176 can only be adopted by
building OpenUSD the way ASWF already built it, which means provisioning Ptex
headers first.** There is no configuration-only route to it.

## The costs, stated plainly

1. **A new build stage.** USD is roughly an order of magnitude more source than
   any delegate here. Free GHA absorbs the cost, but wall-clock per image
   roughly triples and the build becomes the fragile step.
2. **The conan stack's ABI.** The base's libraries were compiled by Conan with
   one toolchain; rebuilding USD against them in the same image is feasible but
   is exactly the mixing risk recorded in `docs/adding-a-renderer-to-the-annual-images.md`
   for the old Cycles dependency bundle. The mitigation is a **separate prefix**
   (`/opt/usd-patched`), never over `/usr/local`, so the stock stack stays intact
   and the change is reversible.
3. **hdStorm and hdEmbree are in-tree.** A source USD build emits its own
   `hdStorm`, and `hdEmbree` is built against the prebuilt USD today. Rebuilding
   USD therefore changes what `hdStorm` *is* in the image, which touches every
   pixel-comparison control the `.3`/`.4` canaries are judged against.
4. **It is a fork pin.** Both PRs are unmerged, so the image would carry
   patched USD indefinitely, and every recorded timing would describe a stack
   the ASWF images do not ship.

## Recommendation

**Do not add the build stage yet.** The two PRs are blocked upstream and waiting
there costs nothing; a source build costs a fragile stage and invalidates the
canary controls.

What is worth doing now, in order:

1. **Land #4238 alone as a pure-Python delta.** It is one file, already present
   in every image at
   `/usr/local/lib/python*/site-packages/pxr/UsdAppUtils/rendererArgs.py`, so it
   needs no rebuild. It would retire the `HD_DEFAULT_RENDERER=GL` workaround in
   `Dockerfile.runnable` and fix GH #49 at its source. Treat it as a labelled
   delta, exactly like the delegate patches.
2. **Keep #4176 tracked** as depending on ASWF shipping a corrected OpenUSD
   recipe. It is the more valuable of the two (Moana Island renders) and the one
   that genuinely needs a build.
3. **Revisit the build stage** when something else already requires rebuilding
   USD, so it is not carried by one blocked PR.

If the build stage is ever authorised, provision Ptex headers from conan-center
**before** anything else — `PXR_ENABLE_PTEX_SUPPORT=OFF` is not an acceptable
fallback, and the failure it causes is a compile error rather than a configure
error, so it will not be caught by a configure-only gate.