#!/usr/bin/env bash
# rebuild nccl with sm_121 sass and overlay it onto an existing pytorch image.
# run on a gb10 host with docker access. takes ~15-25 min (make -j1 is deliberate —
# don't try to give'r with -j$(nproc), it'll fail at nvlink, ask me how i know).
set -euo pipefail

cd "$(dirname "$0")"

BASE_IMAGE="${BASE_IMAGE:?set BASE_IMAGE to your existing pytorch+vllm image}"
TAG="${TAG:?set TAG to the output image tag (e.g. local/mystack:nccl121)}"
NCCL_REF="${NCCL_REF:-v2.28.9-1}"
CUDA_DEVEL_IMAGE="${CUDA_DEVEL_IMAGE:-nvidia/cuda:13.0.0-devel-ubuntu24.04}"

echo "BASE_IMAGE       = $BASE_IMAGE"
echo "TAG              = $TAG"
echo "NCCL_REF         = $NCCL_REF"
echo "CUDA_DEVEL_IMAGE = $CUDA_DEVEL_IMAGE"
echo

docker build \
  --progress=plain \
  --build-arg BASE_IMAGE="$BASE_IMAGE" \
  --build-arg NCCL_REF="$NCCL_REF" \
  --build-arg CUDA_DEVEL_IMAGE="$CUDA_DEVEL_IMAGE" \
  --tag "$TAG" \
  --file Dockerfile \
  .

echo
echo "=== verify sm_121 in the new libnccl ==="
docker run --rm --entrypoint bash "$TAG" -c \
  'find /opt /usr -name libnccl.so.2 -not -path "*/nccl-sm121/*" 2>/dev/null | head -1 | xargs cuobjdump --list-elf 2>&1 | head -10'

echo
echo "done: $TAG"
echo "ship to the other node:   docker save $TAG | ssh <peer> 'docker load'"
