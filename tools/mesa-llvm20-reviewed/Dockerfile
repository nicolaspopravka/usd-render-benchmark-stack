# syntax=docker/dockerfile:1.7

# Rebuild ASWF's Mesa 23.1.4 swrast driver with the LLVM 20 fixes needed by
# Storm's software OpenGL path. The base image already contains LLVM 20.1.7,
# Mesa build dependencies, and the ASWF driver layout.
ARG BASE_IMAGE=ghcr.io/nicolaspopravka/usd-render-benchmark:2026-74db2d237e93

FROM ${BASE_IMAGE} AS mesa-build

RUN python3 -m pip install --quiet mako pyyaml setuptools "meson>=1.4,<2"

RUN curl -fsSL https://archive.mesa3d.org/mesa-23.1.4.tar.xz -o /tmp/mesa.tar.xz \
 && echo "7261a17fb94867e3dc5a90d8a1f100fa04b0cbbde51d25302c0872b5e9a10959  /tmp/mesa.tar.xz" | sha256sum -c -

RUN mkdir -p /src \
 && tar -xJf /tmp/mesa.tar.xz -C /src --strip-components=1

COPY patches /patches
RUN cd /src \
 && for p in /patches/*.patch; do patch -p1 < "$p"; done

RUN /usr/local/bin/meson setup /build /src \
      --prefix=/usr/local \
      --libdir=lib \
      -Dbuildtype=release \
      -Dstrip=true \
      -Dgallium-drivers=swrast \
      -Dvulkan-drivers= \
      -Dplatforms= \
      -Dglx=disabled \
      -Dgbm=disabled \
      -Dosmesa=true \
      -Dllvm=enabled \
      -Dshared-llvm=enabled \
      -Degl=enabled \
      -Degl-native-platform=surfaceless \
      -Dshared-glapi=enabled \
 && ninja -j 2 -C /build \
 && DESTDIR=/mesa-root ninja -C /build install

FROM ${BASE_IMAGE}

COPY --from=mesa-build /mesa-root/usr/local/lib/dri/swrast_dri.so /usr/local/lib/dri/swrast_dri.so
COPY --from=mesa-build /mesa-root/usr/local/lib/libglapi.so.0.0.0 /usr/local/lib/libglapi.so.0.0.0

RUN ln -sf libglapi.so.0.0.0 /usr/local/lib/libglapi.so.0 \
 && ln -sf libglapi.so.0 /usr/local/lib/libglapi.so \
 && ldconfig
