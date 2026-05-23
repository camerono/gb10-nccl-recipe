#!/usr/bin/env bash
# run bench.py across two gb10 nodes with the merged-hca env vars.
# rank 0 is the local host; rank 1 is $PEER (ssh-reachable, docker access, same image).
# if the merge is working you'll see *both* hcas in the `NET/IB : Using [...]` line.
# if you only see one, double-check both pcie-domain halves are up and ip-addressed.
#
# usage (on rank-0 node):
#   TAG=local/mystack:nccl121 PEER=user@10.10.20.2 MASTER_ADDR=10.10.20.1 \
#     bash bench-merged.sh
set -euo pipefail

TAG="${TAG:?set TAG to the image with the sm_121 nccl overlay}"
PEER="${PEER:?set PEER to user@peer-ip (must have docker access + the image loaded)}"
MASTER_ADDR="${MASTER_ADDR:?set MASTER_ADDR to the rank-0 ip reachable from PEER}"
MASTER_PORT="${MASTER_PORT:-29500}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ENVFILE="$HERE/nccl.env"
BENCH="$HERE/bench.py"

# stage bench.py + env file to /tmp on the peer
scp "$BENCH" "$ENVFILE" "$PEER:/tmp/" >/dev/null

# rank 1 — peer, backgrounded
ssh -f "$PEER" "nohup docker run --rm --gpus all --network host --ipc host \
  --device=/dev/infiniband --cap-add=IPC_LOCK --ulimit memlock=-1 \
  --entrypoint python3 \
  -v /tmp/bench.py:/tmp/bench.py \
  --env-file /tmp/nccl.env \
  -e MASTER_ADDR=$MASTER_ADDR -e MASTER_PORT=$MASTER_PORT -e WORLD_SIZE=2 -e RANK=1 \
  $TAG /tmp/bench.py > /tmp/nccl-r1.log 2>&1 &"

echo "rank-1 launched on $PEER; sleeping 4s before rank-0"
sleep 4

# rank 0 — local foreground
docker run --rm --gpus all --network host --ipc host \
  --device=/dev/infiniband --cap-add=IPC_LOCK --ulimit memlock=-1 \
  --entrypoint python3 \
  -v "$BENCH:/tmp/bench.py" \
  --env-file "$ENVFILE" \
  -e MASTER_ADDR="$MASTER_ADDR" -e MASTER_PORT="$MASTER_PORT" -e WORLD_SIZE=2 -e RANK=0 \
  "$TAG" /tmp/bench.py 2>&1 | tee /tmp/nccl-r0.log

echo
echo "=== merge check ==="
grep -E "MERGE_NICS|NET/IB.*Using|allreduce" /tmp/nccl-r0.log | head -10
