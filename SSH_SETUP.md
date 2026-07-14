# SSH Access to HPC Nodes via Tailscale

## Overview

SSH into HPC nodes from Windows WSL using **reverse SSH tunnels** — the HPC
initiates an outbound connection to Windows, which then acts as the entry point.

```
HPC node ──(outbound SSH via Tailscale)──► Windows WSL sshd
              └── reverse tunnel: Windows:PORT ──► HPC:localhost:2222 (sshd)

You (Windows WSL): ssh -p PORT glider@localhost
```

---

## Nodes

| Node | Hostname | GPU | Tailscale IP | Tunnel Port | Connect |
|---|---|---|---|---|---|
| node-01 | c16g2-01-6cb8cf996d-9gg56 | — | 100.112.166.47 | 2200 | `bash ~/hpc-connect-s1.sh` |
| node-02 | c16g2-02-8f7bc676c-2x56f | 2× A100-SXM4-40GB | 100.96.166.60 | 2202 | `bash ~/hpc-connect-s2.sh` |
| node-03 | c16g2-03-576fd5d65-jfzq5 | — | 100.75.231.113 | 2204 | `bash ~/hpc-connect-s3.sh` |

**Windows WSL:** `unix@100.76.251.19` (desktop-a53mumh-1)

---

## Prerequisites

**On each HPC node:**
- Tailscale binaries at `~/tools/tailscale/`
- SSH host keys at `~/.ssh/ssh_host_ed25519_key`, `~/.ssh/ssh_host_rsa_key`
- Outbound key at `~/.ssh/id_ed25519`
- Scripts: `~/start-services.sh`, `~/reverse-tunnel.sh`, `~/watchdog-loop.sh`

**On Windows WSL:**
- `openssh-server` installed and running (`sudo systemctl status ssh`)
- Both HPC nodes' public keys in `~/.ssh/authorized_keys`
- Connect scripts: `~/hpc-connect-s1.sh`, `~/hpc-connect-s2.sh`

---

## After a Pod Restart

Run this **once** in the code-server terminal on the restarted node:

```bash
bash ~/start-services.sh
```

This starts in order:
1. `tailscaled` (Tailscale daemon, userspace networking)
2. `sshd` (on port 2222)
3. `tailscale serve` (fallback, non-critical)
4. `reverse-tunnel.sh` (self-healing tunnel loop)
5. `watchdog-loop.sh` (monitors and auto-restarts everything)

---

## Connecting

```bash
bash ~/hpc-connect-s1.sh   # node-01
bash ~/hpc-connect-s2.sh   # node-02 (2× A100)
bash ~/hpc-connect-s3.sh   # node-03
```

Or directly:
```bash
ssh -p 2200 glider@localhost   # node-01
ssh -p 2202 glider@localhost   # node-02
ssh -p 2204 glider@localhost   # node-03
```

---

## Adding a New Node

Use the one-click setup script (see `setup-new-node.sh`):

```bash
# On the new HPC node — fill in TUNNEL_PORT (next available: 2202, 2203, ...)
bash <(curl -fsSL https://raw.githubusercontent.com/windx987/hpc-tunnel/master/setup-new-node.sh) 2202
```

Then on Windows WSL, add the printed public key to `~/.ssh/authorized_keys` and
create `~/hpc-connect-s3.sh` (copy s1, change port to 2202).

---

## WSL authorized_keys

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKXG3K8DvnPr4xGJTO4do1Ebkwyb3dsADQWfktCnpfqe glider@c16g2-01-6cb8cf996d-9gg56
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ8VeimyP2ENeoM2zqoVdwD6GRgCkxPmC7L+sKhrem5T glider@c16g2-02-8f7bc676c-2x56f
```

---

## Running Training Jobs (tmux via SSH)

```bash
bash ~/hpc-connect-s2.sh
tmux new -s training
python train.py
# Detach: Ctrl+B then D
# Reattach later: tmux attach -t training
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Connection refused` on port 2200/2202 | Tunnel down — run `bash ~/start-services.sh` on the HPC node |
| `remote port forwarding failed` | Stale port on Windows — self-heals automatically |
| `Permission denied (publickey)` | HPC key not in Windows `~/.ssh/authorized_keys` |
| Tunnel keeps dropping | Check `ClientAliveInterval 60` in Windows `/etc/ssh/sshd_config` |
| Check tunnel status | On HPC: `tail -10 ~/.tailscale/tunnel.log` |

---

## Limitations

- **Ephemeral processes** — `tailscaled`, `sshd`, and `reverse-tunnel.sh` don't survive pod restarts. Run `bash ~/start-services.sh` after each restart.
- **Userspace networking only** — Tailscale runs `--tun=userspace-networking`. Only outbound connections from HPC are reliable; the reverse tunnel works around this.
- **Windows WSL sshd must be running** — If Windows restarts, run `sudo service ssh start` on WSL.
- **No password auth** — SSH key only.
