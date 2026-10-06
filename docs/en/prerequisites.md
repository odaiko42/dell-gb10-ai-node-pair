# Prerequisites

🌐 **Language / Langue:** English (current) · [Français](../prerequisites.md)

## Hardware

- 2 × GB10 nodes (or equivalent NVIDIA Grace Blackwell, unified memory), 128 GB each.
- ConnectX-7 network card (or equivalent 200 GbE / InfiniBand) on each node, with a compatible
  cable validated by the vendor (DAC/AOC, QSFP form factor, correct length and firmware — do not
  pick a cable just because the connector seems to fit).
- An existing management network (LAN) for administration, independent of the CX7 link.

## Checks before cabling

"GB10 128 GB" alone does not guarantee software compatibility: GB10 is the processor, partner
products may differ. Before following this guide, check on both machines:

```bash
hostnamectl
uname -m
cat /etc/os-release
nvidia-smi
nvcc --version
ip -br link
ip -br addr
ip route
lspci -nn
ibdev2netdev
rdma link show
free -h
df -h
```

If `nvcc`, `ibdev2netdev` or `rdma` are missing, note their absence and install the corresponding
packages after version verification — do not install a generic driver on top of the vendor image
without a compatible procedure.

## Software

- Linux OS (Ubuntu/Debian or vendor equivalent), NVIDIA driver and CUDA matching the Blackwell
  architecture (`sm_121`/`sm_121a`).
- A reproducible containerized environment rather than system-installed packages: the scripts in
  this repository use an official NVIDIA image (`nvcr.io/nvidia/pytorch:...`) identical on both
  nodes, with build tools already present (cmake, gcc, nvcc) to compile
  [llama.cpp](https://github.com/ggml-org/llama.cpp) with CUDA support + RPC backend
  (`-DGGML_CUDA=ON -DGGML_RPC=ON`).
- `rsync`/`scp` or equivalent to sync the compiled binary between both nodes (same image, no
  recompilation needed on the second node).
- `docker` with the `nvidia` runtime registered (`nvidia-ctk runtime configure --runtime=docker`).

## Dedicated account and access

- A dedicated compute account (no sudo rights required to run jobs), identical on both nodes.
- An SSH key pair dedicated to the inter-node link (see [networking.md](networking.md#ssh)), never
  reused for other access.

## Recommended strict constraints

Regardless of the environment, it is recommended to set safety guards before any intervention:

- Never modify boot parameters (GRUB) as part of this guide.
- Never trigger a system/driver/firmware update without an explicit, separate decision, even if a
  diagnostic command suggests it.
- If either node is already running production workloads, perform read-only/diagnostic operations
  on it only until the procedure has been validated on a non-critical node.
