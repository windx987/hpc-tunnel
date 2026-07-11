# hpc-tunnel

Reliable SSH access to HPC Kubernetes pods (Tailscale userspace networking)
via self-healing reverse SSH tunnels to a Windows WSL machine.

```
HPC node-01 ──(outbound SSH via Tailscale)──► Windows WSL
                └── reverse tunnel: Windows:2200 ──► node-01:localhost:2222

HPC node-02 ──(outbound SSH via Tailscale)──► Windows WSL
                └── reverse tunnel: Windows:2201 ──► node-02:localhost:2222
```

## Nodes

| Node | Hostname | GPU | Tunnel Port | Connect Script |
|---|---|---|---|---|
| node-01 | c16g2-01-6cb8cf996d-9gg56 | — | 2200 | `hpc-connect-s1.sh` |
| node-02 | c16g2-02-8f7bc676c-2x56f | 2× A100-SXM4-40GB | 2201 | `hpc-connect-s2.sh` |

## Files

| File | Runs on | Purpose |
|---|---|---|
| `start-services.sh` | HPC | One command to bring everything up (run after every pod restart) |
| `reverse-tunnel.sh` | HPC | Self-healing tunnel loop: clears stale Windows sessions, reconnects on failure |
| `watchdog-loop.sh` | HPC | Restarts tailscaled/sshd/tunnel if down; end-to-end probe kills stalled streams |
| `https-proxy.py` | HPC | Local HTTPS CONNECT proxy (:18080) so the VS Code tunnel CLI works behind code-server |
| `sshd_config` | HPC | sshd config for port 2222 (lives at `~/.ssh/sshd_config`) |
| `hpc-connect-s1.sh` | Windows WSL | Connect to node-01 (`ssh -p 2200 glider@localhost`) |
| `hpc-connect-s2.sh` | Windows WSL | Connect to node-02 (`ssh -p 2201 glider@localhost`) |

On the HPC, the scripts live in `~/hpc-tunnel/` and are symlinked into `~/`.

## Usage

After a pod restart, on the HPC node:
```bash
bash ~/start-services.sh
```

To connect from Windows WSL:
```bash
bash ~/hpc-connect-s1.sh   # node-01
bash ~/hpc-connect-s2.sh   # node-02 (2× A100)
```

Everything else self-heals: transport stalls, stale port bindings, tailscaled
crashes, and wiped apt packages are all recovered automatically within ~1 minute.

See `SSH_SETUP.md` and `REVERSE_TUNNEL.md` for full setup and troubleshooting.
