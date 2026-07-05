# SSH Access to HPC Node via Tailscale

## Overview

This documents how to SSH into this HPC node from a Windows/WSL machine using a **reverse SSH tunnel** — the primary and most reliable method. A secondary method via `tailscale serve` is documented at the end but is unreliable due to a Tailscale bug.

---

## How It Works (Reverse Tunnel)

Instead of connecting inbound to the HPC (which is broken via `tailscale serve`), the HPC initiates an outbound SSH connection to your Windows machine and creates a reverse tunnel. You then SSH into the HPC through that tunnel from Windows.

```
HPC ──(outbound SSH via Tailscale)──► Windows WSL sshd
         └── reverse tunnel: Windows:2200 ──► HPC:localhost:2222 (sshd)

You (Windows): ssh -p 2200 glider@localhost
```

---

## Prerequisites

**On HPC:**
- Tailscale binaries at `/home/glider/tools/tailscale/`
- HPC SSH key at `~/.ssh/id_ed25519` (already generated)

**On Windows WSL:**
- `openssh-server` installed and running
- HPC public key in `~/.ssh/authorized_keys`
- `hpc-connect.sh` saved to `~/hpc-connect.sh`

---

## One-Time Setup

### On the HPC node

Already done. Files are in place:
- `~/.ssh/sshd_config` — sshd on port 2222
- `~/.ssh/ssh_host_*` — host keys
- `~/.ssh/id_ed25519` — HPC's outbound key
- `~/start-services.sh` — starts everything
- `~/reverse-tunnel.sh` — keeps reverse tunnel alive

### On Windows WSL

**1. Install and start sshd:**
```bash
sudo apt install openssh-server -y
sudo service ssh start
```

**2. Add HPC's public key:**
```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKXG3K8DvnPr4xGJTO4do1Ebkwyb3dsADQWfktCnpfqe glider@c16g2-01-6cb8cf996d-9gg56" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

**3. Copy the connect script from HPC (once tunnel is up):**
```bash
scp -P 2200 glider@localhost:~/hpc-connect.sh ~/hpc-connect.sh
chmod +x ~/hpc-connect.sh
```

---

## After a Pod Restart

Run this **once** in the code-server terminal:

```bash
bash ~/start-services.sh
```

This starts in order:
1. `tailscaled` (Tailscale daemon)
2. `sshd` (on port 2222)
3. `tailscale serve` (fallback, port 2222)
4. `reverse-tunnel.sh` (HPC → Windows tunnel)
5. `watchdog-loop.sh` (monitors and auto-fixes)

---

## Connecting

### From Windows WSL (primary method)

```bash
bash ~/hpc-connect.sh
```

Or directly:
```bash
ssh -p 2200 glider@localhost
```

### Running long training jobs (tmux via SSH)

```bash
bash ~/hpc-connect.sh
tmux new -s training
python train.py
# Detach: Ctrl+B then D
```

Reattach later:
```bash
bash ~/hpc-connect.sh
tmux attach -t training
```

### File transfer from Windows WSL

```bash
# Upload to HPC
scp -P 2200 localfile.py glider@localhost:~/

# Download from HPC
scp -P 2200 glider@localhost:~/results.csv ./
```

---

## Tailscale Network Reference

| Machine | Tailscale IP | Notes |
|---|---|---|
| HPC node | `100.112.166.47` | This machine |
| Desktop (Linux/WSL) | `100.76.251.19` | `desktop-a53mumh-1` — reverse tunnel target |
| Desktop (Windows) | `100.119.188.24` | `desktop-a53mumh` |
| MacBook Air | `100.79.181.13` | Offline |

---

## Keeping Training Alive When Browser Tab is Closed

### The problem

The HPC runs `code-server` (VS Code in browser). When you close the browser tab, code-server's proxy eventually kills the terminal PTY and everything running in it — including tmux started inside the code-server terminal.

### Solution — SSH + tmux (recommended)

A tmux session started over SSH is fully independent of code-server and survives browser disconnects.

```bash
bash ~/hpc-connect.sh
tmux new -s training
python train.py
# Detach: Ctrl+B then D
```

### Solution — nohup (no SSH needed)

```bash
nohup python train.py > ~/train.log 2>&1 &
echo $! > ~/train.pid
tail -f ~/train.log          # monitor
kill -0 $(cat ~/train.pid)   # check if alive
```

### Solution — screen

```bash
screen -S training && python train.py
# Detach: Ctrl+A then D
# Reattach: screen -r training
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Connection refused` on port 2200 | Tunnel down — self-heals within ~40s; if not, run on HPC: `bash ~/start-services.sh` |
| `remote port forwarding failed` | Stale port on Windows — self-heals: the tunnel loop kills the stale session before each reconnect |
| `Permission denied (publickey)` | HPC key not in Windows `~/.ssh/authorized_keys` — re-add key |
| Tunnel keeps dropping | Add to Windows `/etc/ssh/sshd_config`: `ClientAliveInterval 60` then `sudo service ssh restart` |
| Check tunnel status | On HPC: `cat ~/.tailscale/tunnel.log \| tail -10` |

---

## Limitations

### Ephemeral processes
`tailscaled`, `sshd`, and `reverse-tunnel.sh` must be restarted after each pod restart. Run `bash ~/start-services.sh`.

### Windows WSL sshd must be running
The reverse tunnel requires your Windows WSL sshd to be up. If Windows restarts, run `sudo service ssh start` on WSL before trying to connect.

### Userspace networking only
Tailscale runs with `--tun=userspace-networking` (no `/dev/net/tun` in this container). The Tailscale IP is not a real interface — only outbound connections from HPC work reliably. This is why the reverse tunnel is needed.

### tailscale serve is unreliable (do not use as primary)
`tailscale serve --tcp` in userspace mode has a goroutine freeze bug — data stops forwarding between the Tailscale virtual network and sshd even though TCP connections are established on both sides. A watchdog attempts to auto-fix this but the reverse tunnel method is preferred.

### No password authentication
SSH key auth only. Public key must be in `~/.ssh/authorized_keys` on HPC and HPC's key must be in `~/.ssh/authorized_keys` on Windows.

---

## Files Reference

| File | Location | Purpose |
|---|---|---|
| `start-services.sh` | HPC `~/` | Starts all services after pod restart |
| `reverse-tunnel.sh` | HPC `~/` | Persistent reverse tunnel to Windows |
| `watchdog-loop.sh` | HPC `~/` | Auto-fixes frozen SSH connections |
| `hpc-connect.sh` | Windows `~/` | One-command SSH into HPC |
| `~/.ssh/sshd_config` | HPC | sshd on port 2222 |
| `~/.ssh/id_ed25519` | HPC | HPC outbound SSH key |
| `REVERSE_TUNNEL.md` | HPC `~/` | Detailed reverse tunnel docs |
| `SSH_SETUP.md` | HPC `~/` | This file |
