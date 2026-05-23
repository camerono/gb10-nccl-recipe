# syntax=docker/dockerfile:1.6
#
# rebuild nccl with sm_121 sass for gb10 and overlay onto an existing pytorch image.
#
# stock pytorch wheels ship libnccl.so for sm_75/80/90/100/110/120 — no sm_121.
# on gb10 (compute capability 12.1) nccl jit-compiles from ptx at runtime, which
# adds overhead on every collective launch. rebuilding from source with the right
# gencode replaces the runtime jit with native sass.
#
# notes on the build:
#   - `make -j1` is deliberate. parallel builds on v2.28.9-1 race against the
#     generate.py manifest step and fail with `Undefined reference to 'ncclDevFuncTable'`
#     at the nvlink stage. yes it's slower. it'll outlast slayer's *reign in blood*
#     end-to-end, probably twice. go put the kettle on.
#   - python3 must be installed in the builder image (generate.py uses it).
#
# usage:
#   docker build -t <tag> \
#     --build-arg BASE_IMAGE=<your image> \
#     --build-arg NCCL_REF=v2.28.9-1 .

ARG BASE_IMAGE
ARG NCCL_REF=v2.28.9-1
ARG CUDA_DEVEL_IMAGE=nvidia/cuda:13.0.0-devel-ubuntu24.04

FROM ${CUDA_DEVEL_IMAGE} AS builder
ARG NCCL_REF
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git build-essential ca-certificates python3 python3-minimal \
 && rm -rf /var/lib/apt/lists/*
RUN git clone -b ${NCCL_REF} --depth 1 https://github.com/NVIDIA/nccl.git /nccl
WORKDIR /nccl
RUN python3 --version
RUN make -j1 src.build \
    NVCC_GENCODE="-gencode=arch=compute_121,code=sm_121 \
                  -gencode=arch=compute_121,code=compute_121"
RUN ls -la /nccl/build/lib/

FROM ${BASE_IMAGE}
COPY --from=builder /nccl/build/lib/     /opt/nccl-sm121/lib/
COPY --from=builder /nccl/build/include/ /opt/nccl-sm121/include/
# locate the venv's nvidia/nccl/lib/ and overlay the sm_121 libnccl.so* on top
RUN set -eux; \
    NCCL_DST=$(find /opt /usr -maxdepth 8 -type d -name nccl -path '*nvidia/nccl*' 2>/dev/null | head -1)/lib; \
    if [ ! -d "$NCCL_DST" ]; then \
      echo "FATAL: could not locate venv nccl lib dir (looked for *nvidia/nccl*/lib under /opt and /usr)"; exit 1; \
    fi; \
    echo "overlay target: $NCCL_DST"; \
    ls -la "$NCCL_DST"/libnccl* || true; \
    cp -a /opt/nccl-sm121/lib/libnccl.so* "$NCCL_DST/"; \
    ls -la "$NCCL_DST"/libnccl*

LABEL org.opencontainers.image.title="gb10 nccl sm_121 overlay" \
      org.opencontainers.image.description="rebuilds nccl with sm_121 sass for nvidia gb10 (dgx spark / asus gx10 / msi edgexpert) and overlays it onto a base image" \
      org.opencontainers.image.source="https://github.com/camerono/gb10-nccl-recipe"
