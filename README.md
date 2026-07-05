# hpc-tunnel

Reliable SSH access to an HPC Kubernetes pod (Tailscale userspace networking)
via a self-healing reverse SSH tunnel to a Windows WSL machine.

```
HPC ──(outbound SSH via Tailscale)──► Windows WSL
        └── reverse tunnel: Windows:2200 ──► HPC:localhost:2222 (sshd)
```

## Files

| File | Runs on | Purpose |
|---|---|---|
| `start-services.sh` | HPC | One command to bring everything up (run after every pod restart) |
| `reverse-tunnel.sh` | HPC | Self-healing tunnel loop: clears stale Windows sessions, reconnects on failure |
| `watchdog-loop.sh` | HPC | Restarts tailscaled/sshd/tunnel if down; end-to-end probe kills stalled streams |
| `https-proxy.py` | HPC | Local HTTPS CONNECT proxy (:18080) so the VS Code tunnel CLI works behind code-server |
| `sshd_config` | HPC | sshd config for port 2222 (lives at `~/.ssh/sshd_config`) |
| `hpc-connect.sh` | Windows WSL | User-facing connect script (`ssh -p 2200 glider@localhost`) |

On the HPC, the scripts live here and are symlinked into `~/` (e.g.
`~/start-services.sh → ~/hpc-tunnel/start-services.sh`), so documented commands
keep working.

## Usage

After a pod restart, on the HPC:
```bash
bash ~/start-services.sh
```

To connect, on Windows WSL:
```bash
bash ~/hpc-connect.sh
```

Everything else self-heals: transport stalls, stale port bindings, tailscaled
crashes, and wiped apt packages are all recovered automatically within ~1 minute.

See `SSH_SETUP.md` and `REVERSE_TUNNEL.md` for full setup and troubleshooting.
