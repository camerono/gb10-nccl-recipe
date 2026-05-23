# gb10-nccl-recipe

what it takes to get nccl past 12 gbps on a pair of nvidia gb10 boxes (dgx spark, asus ascent gx10, msi edgexpert — same soc, same kerfuffle, same fix) connected by a single qsfp56 cable. the official playbook gets you halfway. this gets you the rest.

## tl;dr

two things, both required:

1. **rebuild nccl with sm_121.** stock pytorch wheels ship sm_75/80/90/100/110/120. no sm_121. gb10 *is* sm_121. without the sass nccl jit-compiles from ptx at runtime, which sounds harmless and is not.
2. **list both pcie-domain halves of the cabled port + `NCCL_IB_MERGE_NICS=1`.** the cx-7 nic exposes each physical qsfp port as two rdma hcas, one per pcie domain. one cable, two devices. miss this and you cap at half line-rate, like trying to play *Eruption* with one guitar string. i could not find this in any official nvidia doc.

with both: ~24 gbps allreduce. with only (1): still 12 gbps. with only (2): 24 gbps but kernels jit at runtime which adds overhead on every collective. (1) is correctness, (2) is the actual speedup.

## results

measured on a pair of asus ascent gx10, single qsfp56 cable, kernel 6.17.0-1018-nvidia, cx-7 firmware 28.45.4028, nccl v2.28.9-1, pytorch 2.11+cu130:

| config | allreduce 1gb |
|---|---|
| stock pytorch nccl, single hca | 11.5 gbps |
| sm_121 rebuild, single hca | 11.5 gbps |
| sm_121 + dual hca + MERGE_NICS=1 | **24.1 gbps** |

`ib_write_bw` on the same fabric: 109 gbps unidirectional. the 24 gbps allreduce ceiling reflects ring-allreduce overhead on a cpu-staged path. there is no path to "200 gbps allreduce" on this platform — see next section.

## gdr is off, and that's fine

Every gb10 nccl log says `use ring PXN 0 GDR 0`. spent a day chasing this. it's architectural. gb10's unified-memory soc has no discrete gpu memory for an rdma nic to address. `nvidia-peermem` does not load. `dma-buf` does not work. nvidia kb #5780 says so explicitly. cpu-staged rdma is the only path and ~24 gbps allreduce is its ceiling.

If you're staring at `GDR 0` and trying to flip it: stop. it's not flipping. (I tried. for the better part of a day -- as God is my witness, i thought GDR would fly.)

## what's in here

| file | what it does |
|---|---|
| `Dockerfile` + `build.sh` | overlay sm_121 nccl onto an existing pytorch image |
| `nccl.env` | env vars that get you the 2x |
| `bench.py` | small torch.distributed allreduce sweep for repro |
| `bench-merged.sh` | runs the bench across 2 nodes with the merged-hca env |
| `setup-second-half.sh` | networkmanager profile for the second pcie-domain ip |

## setup

```bash
# on each node — assigns 10.10.21.<n>/24 to enp1s0f1np1 via networkmanager
sudo bash setup-second-half.sh <last-octet>     # 1 on first box, 2 on second

# sanity check: both halves up, peer ping over the new /24
ibdev2netdev
ping -c 2 -I enp1s0f1np1 <peer 10.10.21 ip>

# build the sm_121 nccl image on one node, then docker save | docker load to the other
TAG=local/mystack:nccl121 BASE_IMAGE=<your existing pytorch image> ./build.sh

# bench it
bash bench-merged.sh
```

what you want to see in the nccl init log:
```
NET/IB : Using [0]rocep1s0f1:1/RoCE [1]roceP2p1s0f1:1/RoCE [RO]
```

both hcas in the `Using` line = merge is on. one hca = your env didn't propagate or the other half is down.

## caveats

- interface names (`enp1s0f1np1`, `enP2p1s0f1np1`) vary by udev rules + firmware. check `ibdev2netdev` first — yours might be `enp1s0f0np0` etc if you cabled port 0 instead of port 1, and the pcie-domain prefix (lowercase vs `P2`) is system-dependent.
- the gid index for ipv4 rocev2 differs **per hca** on the same system (e.g. 3 on one, 5 on the other). don't set `NCCL_IB_GID_INDEX` — `NCCL_IB_ROCE_VERSION_NUM=2` forces rocev2 and lets nccl auto-pick per hca.
- `NCCL_NET_PLUGIN=none` looks paranoid but the bundled aws ofi plugin has a documented dmabuf bug on gb10 (spark forum 366266). leave it off.
- if you have both qsfp cables plugged in: bandwidth halves. plug in one cable. (yes, also a thing, the box would like you to be choosy here, eh.)
- if your cx-7 firmware is older than 28.45.4028 you may have a separate kernel-6.17 regression entirely. flash it via `fwupdmgr` first or you'll be chasing two ghosts in one afternoon.

## why this exists

I bought two of these boxes figuring the official nccl playbook would get me from cable-in to working multi-node in an evening, like a quick doughnut run. it did not. the gap between "official playbook" and "actually 24 gbps" was two days of forum scraping — longer than iron maiden's *rime of the ancient mariner*, and only marginally more rewarding. This repo is what i wish had been the first google result. Sorry the readme runs long, eh.

## hat tip

`karol.spark` on the nvidia developer forums had the original dual-hca recipe (forum thread 366457) — without that post i'd still be on the chesterfield, beer in hand, staring at `GDR 0` like a dope. and to whichever nvidia tech writer left `NCCL_IB_MERGE_NICS=1` out of the official playbook: you're a real piece of work. :-p

## sources

- nvidia kb #5780 — gdr unsupported on dgx spark (architectural)
- nvidia official nccl playbook — https://build.nvidia.com/spark/nccl/stacked-sparks
- nvidia dgx-spark-playbooks — https://github.com/NVIDIA/dgx-spark-playbooks
- asus gx10 community thread with the dual-hca recipe — https://forums.developer.nvidia.com/t/just-another-asus-gx10-nccl-all-gather-perf-thread-mpirun-please-read-if-you-have-an-asus-model-multinode-setup/366457
- aws ofi plugin dmabuf bug — https://forums.developer.nvidia.com/t/nccl-bandwidth-capped-at-3-gb-s-gpu-pcie-topology-reports-gen1-x1-on-dgx-spark-fe/366266

## license

MIT.
