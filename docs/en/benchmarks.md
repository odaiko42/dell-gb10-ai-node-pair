# Detailed benchmark results

🌐 **Language / Langue:** English (current) · [Français](../benchmarks.md)

All measurements below were produced with this repository's scripts, on a pair of real GB10 nodes
(addresses and names anonymized, see [networking.md](networking.md)). Throughput/time values are
specific to the hardware, the model, and the shared node's load at test time — they illustrate a
reproducible measurement method rather than a performance guarantee.

## 1. NCCL collective (`smoke_ddp.py` via `torchrun`, 2 nodes)

| Metric | Value |
|---|---|
| `all_reduce` | 3.0 (identical on both ranks) |

Validates that the CX7 link and NCCL configuration (interfaces, environment variables) allow a
functional inter-node collective, a prerequisite for any distributed training.

## 2. Functional partitioning validation (`test_model_split_rpc.sh`)

| Metric | Value |
|---|---|
| Model | Qwen2.5-3B-Instruct, Q4_K_M (~2 GB) |
| Local VRAM | ~2.9 GiB |
| Remote VRAM (RPC) | ~0.9 GiB |

Confirms that tensors are genuinely split between both nodes (not duplicated), and that the remote
node correctly responds to inference requests.

## 3. Mid-size throughput (`bench_model_split_rpc.sh`, `llama-bench`)

| Metric | Value |
|---|---|
| Model | Qwen2.5-14B-Instruct, Q4_K_M (8.37 GiB) |
| Prompt processing | 1566.75 t/s |
| Generation | 20.35 t/s |
| Local VRAM | ~5.3 GiB |
| Remote VRAM (RPC) | ~3.7 GiB |

## 4. Large-scale test (`bench_scale_model_split_rpc.sh`), ~70B+ model

This test loads a model whose size approaches the combined usable capacity of both nodes, with
auto-adaptive splitting (`-ts`) proportional to the memory actually available at test time, and the
safety guards described in [troubleshooting.md](troubleshooting.md) (periodic memory re-check +
preventive abort during loading).

| Metric | Value |
|---|---|
| Model | Qwen2.5-72B-Instruct, Q4_K_M (~41 GiB, 12 files) |
| Combined usable capacity at test time | ~175.8 GiB (12 GiB safety margin per node) |
| Split (`-ts`) | proportional to each node's free memory |
| Load time | 68.2 s |
| Volume transferred during loading | ~25.1 GiB (sent by the local node, received by the remote node) |
| Network throughput during loading | 3.17 Gb/s (1.6 % of the 200 Gb/s nominal link) |
| Local VRAM after loading | ~17.7 GiB |
| Remote VRAM after loading (RPC process) | ~26.0 GiB |
| Prompt throughput | 51.76 t/s |
| Generation throughput | 4.55 t/s |
| Disruption of existing workloads on the remote node | None (verified by comparing before/after VRAM of pre-existing processes) |

**Observations:**
- The network throughput measured during loading is well below the link's nominal capacity: the
  limiting factor is disk reads and CPU-side tensor deserialization, not network bandwidth.
- Generation throughput is markedly lower than for the 14B model (item 3), which is expected: each
  generated token crosses the network link once more for every layer hosted on the remote node, and
  the gap widens with the number of remote layers.
- The script performed periodic memory re-checks throughout loading without triggering a preventive
  abort, indicating that the applied safety margin (12 GiB) was sufficient under test conditions.

## 5. Network/SSH/RDMA validation (`test_dual_gb10.sh`)

| Metric | Value |
|---|---|
| Result | 9 PASS / 0 FAIL / 1 SKIP |
| Skipped test | `iperf3` not installed on one of the two nodes at measurement time |
