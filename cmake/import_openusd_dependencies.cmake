# OpenUSD's exported garch target references OpenGL::GL. Ensure that imported
# target exists before OpenUSD's pxrTargets.cmake loads. This changes neither
# Cycles nor OpenUSD source.
find_package(OpenGL REQUIRED)

# Load the complete export set before later discovery can define only its main
# target. OpenUSD/MaterialX discovery may load this package config again.
find_package(OpenImageIO CONFIG QUIET)
