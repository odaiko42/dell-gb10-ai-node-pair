# MPI / NCCL

🌐 **Language / Langue:** English (current) · [Français](../mpi-nccl.md)

## Goal

Validate that a minimal NCCL collective (`all_reduce`) works correctly between both nodes over the
CX7 link, before attempting real distributed training. This test does not measure model quality or
memory behavior under load — only collective communication.

## Selecting the network interface for NCCL

Adapt on each node according to the actual interface names (`ip -br link`, `ibdev2netdev`,
`rdma link show`):

```bash
export NCCL_SOCKET_IFNAME='=<cx7_iface_1>,<cx7_iface_2>'
export NCCL_SOCKET_FAMILY=AF_INET
export NCCL_DEBUG=INFO
export NCCL_IB_HCA='=<rdma_dev_1>:1,<rdma_dev_2>:1'
```

Do not copy names observed on another machine. Test automatic selection first before forcing a GID
index. `NCCL_IB_DISABLE=1` is useful to diagnose a fallback to sockets, not to validate that RoCE
works.

## Checking the PyTorch/CUDA environment

```bash
python -c 'import torch; print(torch.__version__); print(torch.cuda.is_available()); \
print(torch.cuda.get_device_name(0)); print(torch.cuda.nccl.version())'
```

## Two-node smoke test

Script: [scripts/smoke_ddp.py](../../scripts/smoke_ddp.py) — identical on both machines.

```bash
# Node-A (rank 0)
torchrun --nnodes=2 --nproc-per-node=1 --node-rank=0 \
  --master-addr=<cx7_ip_A> --master-port=29500 smoke_ddp.py

# Node-B (rank 1)
torchrun --nnodes=2 --nproc-per-node=1 --node-rank=1 \
  --master-addr=<cx7_ip_A> --master-port=29500 smoke_ddp.py
```

Expected: `world_size=2` and `all_reduce=3.0` on each rank (sum of `rank+1` for both ranks). The
first process launched waits for the second — start B before the timeout expires.

Recommended negative test: stop B before the collective and verify that A fails in a bounded way
(timeout turned into an error, resources released), rather than hanging indefinitely.

## Beyond the smoke test

The official [nccl-tests](https://github.com/NVIDIA/nccl-tests) suite (`all_reduce`, `all_gather`,
etc.) allows measuring real throughput (`busbw`) while progressively increasing buffer sizes.
Collective `busbw` and raw Ethernet throughput (Gb/s) are not interchangeable metrics.

## Result measured on this cluster (2 nodes, CX7 interconnect)

| Test | Result |
|---|---|
| `torchrun` 2 nodes, `all_reduce` | `rank=0 world_size=2 all_reduce=3.0` and `rank=1 world_size=2 all_reduce=3.0` — collective validated end to end |
