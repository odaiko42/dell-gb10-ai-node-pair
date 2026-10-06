# Networking

🌐 **Language / Langue:** English (current) · [Français](../networking.md)

## Proposed addressing plan

| Plan | Node-A | Node-B | Usage |
|---|---|---|---|
| Management | `10.0.0.11` (example) | `10.0.0.12` (example) | Administration, SSH, controlled LAN/Internet access |
| CX7 logical 1 | `10.10.0.1/30` | `10.10.0.2/30` | Inter-node compute/transport |
| CX7 logical 2 | `10.10.1.1/30` | `10.10.1.2/30` | Second logical path of the same physical link |

These addresses are a **proposal**, not vendor-mandated values. Verify they don't overlap the LAN,
any VPN, or existing Docker/Kubernetes networks. If they overlap, pick different subnets and
replace them everywhere (including in the scripts' environment variables, see
[../../scripts](../../scripts)).

No gateway, no DNS, and no default route on the CX7 interfaces. Management keeps its existing
default route. No bridge between CX7 and the LAN.

## Netplan configuration (example)

Actual interface names (`ip -br link`, `ibdev2netdev`) are machine-specific — never apply a file
as-is without adapting them. See
[config/netplan/60-cx7.yaml.example](../../config/netplan/60-cx7.yaml.example).

Recommended procedure (run from local/management access, never solely over the link being
configured):

```bash
# Backup before any change
sudo install -d -m 700 /root/cluster-netplan-backup
sudo cp -a /etc/netplan/. /root/cluster-netplan-backup/

# After adapting the file (interface names + real IPs)
sudo chmod 600 /etc/netplan/60-cx7.yaml
sudo netplan generate
sudo netplan try --timeout 120   # automatically rolls back if not confirmed
```

Checks after applying, on each node:

```bash
ip route get <cx7_peer_ip_link1>
ping -c 5 <cx7_peer_ip_link1>
```

Also test persistence after a controlled reboot.

### Rollback

If the new file is the only change: move it out of `/etc/netplan`, re-run `netplan generate`, then
apply from safe local/management access. Do not delete the entire contents of `/etc/netplan`.

## SSH

Use a key dedicated to the inter-node link, never reused elsewhere:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_cluster
ssh-copy-id -i ~/.ssh/id_ed25519_cluster.pub <user>@<cx7_peer_ip>
```

- Verify the remote host key fingerprint via a trusted channel before accepting the connection.
- Never copy a private key between machines.
- Never use `StrictHostKeyChecking=no` as a normal solution.
- Restrict `authorized_keys` by source IP where possible.

Example client configuration: [config/ssh/config.example](../../config/ssh/config.example).

## Port matrix (example)

| Port/protocol | Service | Recommended scope |
|---|---|---|
| TCP 22 | SSH | Management; CX7 between both node IPs if the launch tool uses it |
| TCP dynamic | NCCL bootstrap/sockets, MPI | CX7 interfaces only, exact peer |
| UDP 4791 | RoCEv2 | Between CX7 interfaces of both nodes if RoCE transport is active |
| TCP (chosen RPC port) | llama.cpp RPC backend | Private CX7 only — **never** exposed on the LAN or the Internet (unauthenticated/unencrypted protocol by design) |
| TCP 5201 | iperf3 (one-off diagnostic) | CX7, temporary, close after measurement |

Do not open ports "just in case". If an additional parallelism engine (Ray, etc.) is introduced
later, document its own port matrix before enabling it.

## Validating the physical link

```bash
# Side B (temporary)
iperf3 -s -B <cx7_ip_B>

# Side A
iperf3 -c <cx7_ip_B> -B <cx7_ip_A> -P 4 -t 30
iperf3 -c <cx7_ip_B> -B <cx7_ip_A> -P 4 -t 30 -R
```

The link's nominal throughput is not a guarantee of application-level throughput; `iperf3` only
validates TCP transport, not RoCE/NCCL operation (see [mpi-nccl.md](mpi-nccl.md)).

The script [scripts/test_dual_gb10.sh](../../scripts/test_dual_gb10.sh) automates all of these
checks (management ping, CX7 interfaces, key-based SSH, RDMA, local/remote GPU, and optionally
iperf3 via `--with-iperf3`).
