# Skill: New HPC Node Setup (Tailscale + Reverse Tunnel)

Step-by-step guide to connect a new HPC pod to Windows WSL via Tailscale reverse SSH tunnel.

---

## Prerequisites

- Windows WSL running with `sudo service ssh status` → active
- Tailscale already installed on WSL (not required on HPC — installed below)
- Next available tunnel port (check with `ss -tlnp | grep :22` on WSL; use 2200, 2202, 2204, 2206…)
- Verify the port is bindable on WSL before starting:
  ```bash
  python3 -c "import socket; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('127.0.0.1',PORT)); print('OK'); s.close()"
  ```

---

## Step 1 — Install Tailscale on HPC node

```bash
mkdir -p ~/tools/tailscale ~/.tailscale ~/bin ~/lib
cd /tmp
curl -fsSL https://pkgs.tailscale.com/stable/tailscale_1.98.8_amd64.tgz -o ts.tgz
tar -xzf ts.tgz
cp tailscale_1.98.8_amd64/tailscale tailscale_1.98.8_amd64/tailscaled ~/tools/tailscale/
chmod +x ~/tools/tailscale/tailscale ~/tools/tailscale/tailscaled
```

---

## Step 2 — Start tailscaled and authenticate

```bash
nohup ~/tools/tailscale/tailscaled \
  --tun=userspace-networking \
  --state=~/.tailscale/state \
  --socket=/tmp/tailscale.sock \
  >> ~/.tailscale/tailscaled.log 2>&1 &
sleep 5

# This prints a URL — open it in browser and approve the device
~/tools/tailscale/tailscale --socket=/tmp/tailscale.sock up

# Verify
~/tools/tailscale/tailscale --socket=/tmp/tailscale.sock ip
```

---

## Step 3 — SSH keys

```bash
mkdir -p ~/.ssh
[ ! -f ~/.ssh/ssh_host_ed25519_key ] && ssh-keygen -t ed25519 -f ~/.ssh/ssh_host_ed25519_key -N "" -q
[ ! -f ~/.ssh/ssh_host_rsa_key ]     && ssh-keygen -t rsa -b 4096 -f ~/.ssh/ssh_host_rsa_key -N "" -q
[ ! -f ~/.ssh/id_ed25519 ]           && ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "glider@$(hostname)" -q
```

---

## Step 4 — sshd config + authorized_keys

```bash
cat > ~/.ssh/sshd_config << 'EOF'
Port 2222
HostKey /home/glider/.ssh/ssh_host_ed25519_key
HostKey /home/glider/.ssh/ssh_host_rsa_key
AuthorizedKeysFile /home/glider/.ssh/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
AllowUsers glider
PrintMotd no
LogLevel DEBUG3
EOF

# WSL's public key (allows WSL → HPC SSH)
mkdir -p ~/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKN4KumeqrlTI2Yyj14p8mrGdUNrVLldYZ9dZ5jp7drO terawat.cc@gmail.com" > ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

---

## Step 5 — Start sshd

```bash
# Try system sshd first
SSHD=/usr/sbin/sshd
if [ ! -x "$SSHD" ]; then
  SSHD=~/bin/sshd
fi

if [ ! -x "$SSHD" ]; then
  echo "sshd not found — get it from another node:"
  echo "  On node-01: python3 -m http.server 9002 --directory / &"
  echo "  Then: curl http://NODE01_IP:9002/usr/sbin/sshd -o ~/bin/sshd && chmod +x ~/bin/sshd"
fi

# Fix missing libwrap (common on stripped containers)
if ldd "$SSHD" 2>&1 | grep -q "libwrap.so.0 => not found"; then
  echo "libwrap missing — get from node-01 HTTP server:"
  echo "  curl http://NODE01_IP:9002/lib/x86_64-linux-gnu/libwrap.so.0 -o ~/lib/libwrap.so.0"
  export LD_LIBRARY_PATH=~/lib
fi

sed -i '/PrivilegeSeparation/d' ~/.ssh/sshd_config
pkill -f "sshd.*sshd_config" 2>/dev/null; sleep 1

if [ -n "$LD_LIBRARY_PATH" ]; then
  nohup env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" "$SSHD" -f ~/.ssh/sshd_config >> ~/.tailscale/sshd.log 2>&1 &
else
  nohup "$SSHD" -f ~/.ssh/sshd_config >> ~/.tailscale/sshd.log 2>&1 &
fi
sleep 2

awk '$4=="0A" && $2~/:08AE$/{found=1} END{exit !found}' /proc/net/tcp /proc/net/tcp6 \
  && echo "sshd OK" || echo "FAILED — check ~/.tailscale/sshd.log"
```

---

## Step 6 — Reverse tunnel (replace PORT with your port e.g. 2204)

```bash
PORT=2204   # <-- change this

cat > ~/reverse-tunnel.sh << EOF
#!/bin/bash
LOG=/home/glider/.tailscale/tunnel.log
WIN=unix@100.76.251.19
PROXY="/home/glider/tools/tailscale/tailscale --socket=/tmp/tailscale.sock nc %h %p"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o ConnectTimeout=15
  -o "ProxyCommand=\$PROXY"
)

echo "\$(date) tunnel loop starting (PID \$\$)" >> "\$LOG"

while true; do
  timeout 8 ssh "\${SSH_OPTS[@]}" "\$WIN" '
    pid=\$(ss -tlnp sport = ":${PORT}" 2>/dev/null | grep -oP "pid=\K[0-9]+" | head -1)
    [ -n "\$pid" ] && kill "\$pid" 2>/dev/null
  ' >> "\$LOG" 2>&1

  ssh "\${SSH_OPTS[@]}" -N \\
    -o ExitOnForwardFailure=yes \\
    -o ServerAliveInterval=60 \\
    -o ServerAliveCountMax=5 \\
    -o TCPKeepAlive=yes \\
    -R ${PORT}:localhost:2222 \\
    "\$WIN" >> "\$LOG" 2>&1

  echo "\$(date) tunnel exited, retrying in 10s" >> "\$LOG"
  sleep 10
done
EOF
chmod +x ~/reverse-tunnel.sh
nohup bash ~/reverse-tunnel.sh >> ~/.tailscale/tunnel.log 2>&1 &
sleep 15 && tail -5 ~/.tailscale/tunnel.log
```

---

## Step 7 — Add node's key to WSL authorized_keys

```bash
# On HPC node — print the key
cat ~/.ssh/id_ed25519.pub
```

On **Windows WSL**, add it:
```bash
echo "ssh-ed25519 AAAA...key... glider@hostname" >> ~/.ssh/authorized_keys
```

---

## Step 8 — Create connect script on WSL

```bash
# On Windows WSL
cp ~/hpc-connect-s1.sh ~/hpc-connect-sN.sh
sed -i 's/TUNNEL_PORT="2200"/TUNNEL_PORT="PORT"/' ~/hpc-connect-sN.sh
bash ~/hpc-connect-sN.sh   # test it
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `tailscale up` hangs | It printed a URL — open in browser and approve |
| `sshd FAILED` | Check `~/.tailscale/sshd.log`; likely missing binary or libwrap |
| `remote port forwarding failed` | Port blocked by Windows (Hyper-V reservation) — try next even port |
| `Permission denied (publickey)` | WSL key not in HPC `~/.ssh/authorized_keys` — re-add it |
| Port not bindable on WSL | Run `python3 -c "...bind(PORT)..."` to verify; skip blocked ports |
| Windows sshd blocks WSL sshd port 22 | `powershell.exe -Command "Stop-Service sshd; Set-Service sshd -StartupType Disabled"` |
| Pre-flight SSH hangs | Already fixed: `timeout 8` wraps the pre-flight command |

---

## Node Registry

| Node | Hostname | GPU | Tailscale IP | Port | Connect |
|---|---|---|---|---|---|
| node-01 | c16g2-01-6cb8cf996d-9gg56 | — | 100.112.166.47 | 2200 | `hpc-connect-s1.sh` |
| node-02 | c16g2-02-8f7bc676c-2x56f | 2× A100-SXM4-40GB | 100.96.166.60 | 2202 | `hpc-connect-s2.sh` |
| node-03 | c16g2-03-576fd5d65-jfzq5 | — | 100.75.231.113 | 2204 | `hpc-connect-s3.sh` |

**Next available port: 2206**
