# Reverse SSH Tunnel — HPC Access Method

## Why this exists

`tailscale serve --tcp` in userspace networking mode has a bug where the data-forwarding goroutine freezes, causing SSH to hang indefinitely. The reverse tunnel bypasses this entirely by having the **HPC initiate the connection outbound to Windows** (which works reliably), creating a tunnel that Windows can then use to reach sshd on the HPC.

```
HPC ──(outbound SSH via Tailscale)──► Windows
         └── reverse tunnel: Windows:2200 ──► HPC:localhost:2222 (sshd)
```

---

## Architecture

| Component | Location | Role |
|---|---|---|
| `sshd` | HPC port 2222 | Accepts SSH sessions |
| `reverse-tunnel.sh` | HPC | Self-healing loop: clears stale Windows sessions, reconnects on failure |
| `watchdog-loop.sh` | HPC | Restarts tailscaled / sshd / tunnel loop if any dies |
| Windows sshd | Windows WSL port 22 | Accepts the HPC's outbound connection |
| Reverse tunnel port | Windows port 2200 | Entry point for the user |

The tunnel loop is fully self-healing: before each connect it SSHes to Windows and
kills any stale `sshd-session` still holding port 2200, then connects with
`ExitOnForwardFailure=yes` so a failed bind exits and retries (every 10s) instead
of silently connecting without a forward. No autossh required.

---

## One-time Setup

### On the HPC node

1. Generate an SSH key (already done):
```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub
```

2. Start everything (tailscaled, sshd, tunnel loop, watchdog):
```bash
bash ~/start-services.sh
```

### On Windows WSL

1. Install and start sshd:
```bash
sudo apt install openssh-server -y
sudo service ssh start
```

2. Add the HPC's public key:
```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKXG3K8DvnPr4xGJTO4do1Ebkwyb3dsADQWfktCnpfqe glider@c16g2-01-6cb8cf996d-9gg56" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

3. Save the local helper script (`hpc-connect.sh`) and make it executable:
```bash
chmod +x ~/hpc-connect.sh
```

---

## Daily Usage

### Connecting to HPC

On Windows WSL, run:
```bash
bash ~/hpc-connect.sh
```

Or directly:
```bash
ssh -p 2200 glider@localhost
```

### Checking tunnel status (from HPC)

```bash
cat ~/.tailscale/tunnel.log | tail -10
ps aux | grep "ssh.*unix@100" | grep -v grep
```

### If tunnel is down (from HPC)

Normally unnecessary — the loop retries every 10s and the watchdog restarts the
loop if it dies. If you want to force a clean restart:

```bash
bash ~/start-services.sh
```

---

## After a Pod Restart

Run this one command in the code-server terminal:

```bash
bash ~/start-services.sh
```

It reinstalls openssh-server if the pod restart wiped it, then starts everything.
Then SSH from Windows as normal: `bash ~/hpc-connect.sh`

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Connection refused` on Windows port 2200 | Tunnel is down | Wait ~30s (self-heals); or `bash ~/start-services.sh` on HPC |
| `remote port forwarding failed` | Port 2200 stale on Windows | Self-heals: the loop's pre-flight kills the stale session and retries |
| `Timeout, server not responding` | Tailscale userspace transport stall | Tunnel auto-reconnects within ~40s |
| `Permission denied` | HPC key not in Windows authorized_keys | Re-add key (see setup step 2) |
| Tunnel keeps dropping | Windows sshd ClientAlive settings too strict | Add `ClientAliveInterval 60` to `/etc/ssh/sshd_config` on Windows WSL |

---

## Comparison with tailscale serve method

| | Reverse Tunnel | tailscale serve |
|---|---|---|
| Reliability | Stable | Intermittently frozen |
| Direction | HPC → Windows (outbound) | Windows → HPC (inbound) |
| Requires Windows sshd | Yes | No |
| Port on Windows | localhost:2200 | N/A |
| Port on HPC | localhost:2222 (sshd) | 100.112.166.47:2222 |
| Watchdog needed | No (auto-reconnects) | Yes |
