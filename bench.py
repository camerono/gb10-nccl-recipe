# small torch.distributed allreduce sweep — 1mb through 1gb, fp32.
# enough to tell you whether the merged-hca config is doing what it should
# without making a whole production of it.
#
# env vars: RANK, WORLD_SIZE, MASTER_ADDR, MASTER_PORT — your launcher sets these.
import os, time, datetime
import torch
import torch.distributed as dist

rank = int(os.environ["RANK"])
world = int(os.environ["WORLD_SIZE"])
dist.init_process_group(backend="nccl", init_method="env://",
                        timeout=datetime.timedelta(seconds=60))
device = torch.device("cuda:0")
torch.cuda.set_device(device)

def bench(N, iters_warm=5, iters_meas=20):
    buf = torch.zeros(N, device=device, dtype=torch.float32) + rank
    for _ in range(iters_warm):
        dist.all_reduce(buf)
    torch.cuda.synchronize()
    t0 = time.time()
    for _ in range(iters_meas):
        dist.all_reduce(buf)
    torch.cuda.synchronize()
    dur = (time.time() - t0) / iters_meas
    bytes_per_iter = N * 4
    eff_bw = bytes_per_iter * 2 * (world - 1) / world / dur / 1e9
    return dur * 1000, eff_bw

for size_mb in [1, 16, 64, 256, 1024]:
    N = size_mb * 1024 * 1024 // 4  # fp32 element count
    dur_ms, bw = bench(N)
    if rank == 0:
        print(f"[allreduce] size={size_mb:>5}MB   "
              f"per-iter={dur_ms:7.2f}ms   "
              f"bandwidth={bw:6.2f} GB/s ({bw*8:6.1f} Gbps)", flush=True)

dist.barrier()
