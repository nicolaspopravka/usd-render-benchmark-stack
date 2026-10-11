# OpenUSD's exported garch target references OpenGL::GL. Ensure that imported
# target exists before OpenUSD's pxrTargets.cmake loads. This changes neither
# Cycles nor OpenUSD source.
find_package(OpenGL REQUIRED)