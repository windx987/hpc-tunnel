# Reverse SSH Tunnel — HPC Access Method

## Why this exists

`tailscale serve --tcp` in userspace networking mode has a bug where the
data-forwarding goroutine freezes. The reverse tunnel bypasses this entirely:
the **HPC initiates the connection outbound to Windows**, which works reliably.

```
HPC node-01 ──(outbound SSH via Tailscale)──► Windows WSL
                └── reverse tunnel: Windows:2200 ──► node-01:localhost:2222

HPC node-02 ──(outbound SSH via Tailscale)──► Windows WSL
                └── reverse tunnel: Windows:2202 ──► node-02:localhost:2222
```

---

## Architecture

| Component | Location | Role |
|---|---|---|
| `sshd` | HPC port 2222 | Accepts SSH sessions |
| `reverse-tunnel.sh` | HPC | Self-healing loop: clears stale Windows port, reconnects on failure |
| `watchdog-loop.sh` | HPC | Restarts tailscaled / sshd / tunnel loop if any dies; end-to-end probe |
| Windows sshd | WSL port 22 | Accepts the HPC's outbound connection |
| Tunnel port | Windows 2200 / 2202 | Entry point for the user |

### Pre-flight design (important for multi-node)

Before each reconnect, `reverse-tunnel.sh` SSHes to Windows and kills **only
the sshd-session holding its own port** (e.g. node-01 kills the port-2200
session, node-02 kills the port-2202 session). This prevents nodes from
interfering with each other's tunnels.

```bash
# node-01 pre-flight (kills only port 2200 session)
pid=$(ss -tlnp sport = ":2200" | grep -oP "pid=\K[0-9]+" | head -1)
[ -n "$pid" ] && kill "$pid"

# node-02 pre-flight (kills only port 2202 session)
pid=$(ss -tlnp sport = ":2202" | grep -oP "pid=\K[0-9]+" | head -1)
[ -n "$pid" ] && kill "$pid"
```

Using `ExitOnForwardFailure=yes` means a failed port bind exits immediately
so the loop retries (every 10s) instead of silently connecting without a forward.

---

## Daily Usage

Connect from Windows WSL:
```bash
bash ~/hpc-connect-s1.sh   # node-01
bash ~/hpc-connect-s2.sh   # node-02 (2× A100)
```

Check tunnel status (from HPC):
```bash
tail -10 ~/.tailscale/tunnel.log
```

Force a clean restart (from HPC):
```bash
bash ~/start-services.sh
```

---

## After a Pod Restart

```bash
bash ~/start-services.sh
```

Reinstalls openssh-server if wiped, then starts tailscaled → sshd → tunnel → watchdog.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Connection refused` on port 2200/2202 | Tunnel down | Wait ~30s (self-heals); or `bash ~/start-services.sh` on HPC |
| `remote port forwarding failed` | Stale port on Windows | Self-heals: pre-flight kills the stale session before each reconnect |
| `Timeout, server not responding` | Tailscale userspace transport stall | Auto-reconnects within ~40s via watchdog probe |
| `Permission denied` | HPC key not in Windows authorized_keys | Re-add key from `cat ~/.ssh/id_ed25519.pub` on HPC |
| Two nodes' tunnels fighting | Old kill-all pre-flight | Each node's `reverse-tunnel.sh` must only kill its own port (see above) |

---

## Comparison with tailscale serve method

| | Reverse Tunnel | tailscale serve |
|---|---|---|
| Reliability | Stable | Intermittently frozen |
| Direction | HPC → Windows (outbound) | Windows → HPC (inbound) |
| Requires Windows sshd | Yes | No |
| Multi-node | Yes (one port per node) | N/A |
| Port on Windows | localhost:2200, 2202, … | N/A |
