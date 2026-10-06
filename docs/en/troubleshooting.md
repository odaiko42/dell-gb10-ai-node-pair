# Troubleshooting

🌐 **Language / Langue:** English (current) · [Français](../troubleshooting.md)

## Grace Blackwell unified memory: diagnostic pitfall

- `nvidia-smi --query-gpu=memory.total,memory.used,memory.free` may return empty fields (`N/A`)
  depending on the driver version on this architecture. Rely instead on the log of the inference
  engine in use (e.g. llama.cpp's `ggml_cuda_init` prints the actual total VRAM).
- `nvidia-smi --query-compute-apps` only reflects memory attributed to CUDA processes: on a node
  that also runs non-GPU workloads, real memory pressure can be significantly underestimated.
  Always cross-check with `MemAvailable` (`/proc/meminfo`, system memory including reclaimable
  cache) and swap usage before assuming a margin is sufficient:

  ```bash
  awk '/MemAvailable/{print int($2/1024)" MiB"}' /proc/meminfo
  awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{print int((t-f)/1024)" MiB swap used"}' /proc/meminfo
  ```

- **A one-off check before a long operation (loading a large model, several minutes) is not enough
  on a node whose load varies over time**: available memory can degrade significantly during the
  operation. Plan for periodic re-checks during the operation, with an automatic abort mechanism if
  a critical floor is crossed, rather than a single initial check (see
  [scripts/bench_scale_model_split_rpc.sh](../../scripts/bench_scale_model_split_rpc.sh) for an
  example implementation: re-check every N seconds + preventive abort + container cleanup before a
  real OOM occurs).

## System locale and scripts mixing `awk` and `printf`

If the shell is in a decimal-comma locale (e.g. `fr_FR`), a floating-point number produced by `awk`
(decimal point) can make `printf "%f"` fail (`invalid number`). Adding `export LC_ALL=C` at the top
of the script resolves this without affecting the rest of the execution.

## Escaping `$` in an `awk` command run remotely over SSH

When an `awk` command containing field references (`$1`, `$2`) is passed through a shell function
that wraps it in `ssh ... "$cmd"`, a single level of escaping (`\$2`) is enough where the local
shell would otherwise interpret the `$` prematurely. Over-escaping (`\\\\\\$2`) causes a
`awk: backslash not last character on line` error.

## Unexpected sudo password prompt on a normally passwordless node

If a node configured for passwordless `sudo` suddenly starts prompting for one again (expired
session, changed policy, etc.), never type the password into a terminal driven by an automation
tool. Use an equivalent command without `sudo` if the account already belongs to the required group
(e.g. `docker`), or escalate to a human.

## Network interface not detected / different name between nodes

Interface names (`enp1s0f0np0`, etc.) can differ from one node to the other. The scripts in this
repository dynamically detect their own role (A/B) from the local management IPs rather than
assuming a fixed interface name — see the repeated `detectRole`/`role` pattern in each script under
[scripts/](../../scripts).

## `llama-bench` / `llama-server`: `libcuda.so.1: cannot open shared object file` error

The Docker container must be started with `--gpus all` (not just a volume mount) to expose the CUDA
runtime, even for a simple `--help`.

## GGUF repositories split into multiple files

GGUF repositories published by model vendors are frequently split into multiple files
(`model-q4_k_m-00001-of-00003.gguf`, etc.), even for modest sizes. Check the exact file list via
the repository's API before downloading by guessing a URL. `llama.cpp`-based inference engines
natively load the complete model from the path of the first file, with no manual merging required.
