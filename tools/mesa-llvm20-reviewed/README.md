# Reviewed Mesa 23.1.4 / LLVM20 diagnostic

Continues OpenCode's repair without its per-function InstCombine attribute.
New patches are unmodified upstream Mesa commits:

- 550cc685a76b609a3c3f358d554de6e9911510ec, Dave Airlie,
  https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/27133
- 99f0449987bec1f82cd42a06f40bb4a863a37792, Nikita Popov,
  https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/28101

The latter disables fixpoint verification in the explicit InstCombine pipeline
for LLVM>=18, matching upstream Mesa's production behavior. The other two
patches are the existing ASWF PR495 build backports. Runtime selection remains
LIBGL_DRIVERS_PATH=/usr/local/lib/dri. Build base is passed explicitly by the
no-push workflow; only swrast_dri.so and matching libglapi are replaced.
Scope: diagnostic Storm/Teapot only. No images published or profiles promoted.
