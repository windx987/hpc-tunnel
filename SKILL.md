# Skill: New HPC Node Setup (Tailscale + Reverse Tunnel)

Step-by-step guide to connect a new HPC pod to Windows WSL via Tailscale reverse SSH tunnel.

---

## One-liner setup (recommended)

Run this on the HPC node, replacing PORT with the tunnel port:

```bash
curl -fsSL https://raw.githubusercontent.com/windx987/hpc-tunnel/master/setup-new-node.sh | bash -s PORT
```

| Node | Port |
|------|------|
| node-01 | 2200 |
| node-02 | 2202 |
| node-03 | 2204 |
| node-04 | 2206 |

The script will:
1. Install Tailscale binaries
2. Start tailscaled and prompt for auth (open URL in browser)
3. Generate SSH host + outbound keys
4. Write sshd_config
5. Download sshd + libwrap from Ubuntu archive if not present
6. Clone this repo and generate `reverse-tunnel.sh` + `watchdog-loop.sh`
7. Start tunnel and watchdog

When done, it prints a public key. Add it to WSL:
```bash
echo "ssh-ed25519 AAAA...key... glider@hostname" >> ~/.ssh/authorized_keys
ssh-keygen -f ~/.ssh/known_hosts -R '[localhost]:PORT'
```

Test:
```bash
bash ~/hpc-connect-sN.sh
```

---

## Prerequisites

- Windows WSL running with `sudo service ssh status` → active
- Tailscale already installed on WSL
- Verify the port is bindable on WSL before starting:
  ```bash
  python3 -c "import socket; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('127.0.0.1',PORT)); print('OK'); s.close()"
  ```
  If it fails: the port is blocked by Windows Hyper-V. Try next even port.

---

## Manual steps (if script fails)

### Step 1 — Install Tailscale

```bash
mkdir -p ~/tools/tailscale ~/.tailscale ~/bin ~/lib
cd /tmp
curl -fsSL https://pkgs.tailscale.com/stable/tailscale_1.98.8_amd64.tgz -o ts.tgz
tar -xzf ts.tgz
cp tailscale_1.98.8_amd64/tailscale tailscale_1.98.8_amd64/tailscaled ~/tools/tailscale/
chmod +x ~/tools/tailscale/tailscale ~/tools/tailscale/tailscaled
```

### Step 2 — Start tailscaled and authenticate

```bash
nohup ~/tools/tailscale/tailscaled \
  --tun=userspace-networking \
  --state=~/.tailscale/state \
  --socket=/tmp/tailscale.sock \
  >> ~/.tailscale/tailscaled.log 2>&1 &
sleep 6

# Prints a URL — open in browser and approve
~/tools/tailscale/tailscale --socket=/tmp/tailscale.sock up

# Verify
~/tools/tailscale/tailscale --socket=/tmp/tailscale.sock ip
```

> Note: `tailscale status` returns non-zero when not logged in — use `pgrep -f tailscaled` to check if daemon is running.

### Step 3 — SSH keys

```bash
mkdir -p ~/.ssh
[ ! -f ~/.ssh/ssh_host_ed25519_key ] && ssh-keygen -t ed25519 -f ~/.ssh/ssh_host_ed25519_key -N "" -q
[ ! -f ~/.ssh/ssh_host_rsa_key ]     && ssh-keygen -t rsa -b 4096 -f ~/.ssh/ssh_host_rsa_key -N "" -q
[ ! -f ~/.ssh/id_ed25519 ]           && ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "glider@$(hostname)" -q
```

### Step 4 — sshd config + authorized_keys

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

echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKN4KumeqrlTI2Yyj14p8mrGdUNrVLldYZ9dZ5jp7drO terawat.cc@gmail.com" > ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

### Step 5 — sshd binary (Ubuntu 22.04 stripped containers)

`/usr/sbin/sshd` and `apt-get` often unavailable. Download from Ubuntu archive:

```bash
# sshd — pin to 8.9p1 (needs libcrypto.so.3, matches Ubuntu 22.04)
PKG=$(curl -s "http://archive.ubuntu.com/ubuntu/pool/main/o/openssh/" \
  | grep -oP 'openssh-server_8\.9p1[^"]+amd64\.deb' | tail -1)
curl -fsSL "http://archive.ubuntu.com/ubuntu/pool/main/o/openssh/$PKG" -o /tmp/openssh.deb
dpkg -x /tmp/openssh.deb /tmp/openssh-ext
cp /tmp/openssh-ext/usr/sbin/sshd ~/bin/sshd && chmod +x ~/bin/sshd

# libwrap — pin to 7.6.q-31build2 (jammy); newer versions need GLIBC_2.38
curl -fsSL "http://archive.ubuntu.com/ubuntu/pool/main/t/tcp-wrappers/libwrap0_7.6.q-31build2_amd64.deb" \
  -o /tmp/libwrap.deb
dpkg -x /tmp/libwrap.deb /tmp/libwrap-ext
find /tmp/libwrap-ext -name 'libwrap.so*' -exec cp {} ~/lib/ \;
```

Start sshd:
```bash
sed -i '/PrivilegeSeparation/d' ~/.ssh/sshd_config
pkill -f "sshd.*sshd_config" 2>/dev/null; sleep 1
nohup env LD_LIBRARY_PATH=~/lib ~/bin/sshd -f ~/.ssh/sshd_config >> ~/.tailscale/sshd.log 2>&1 &
sleep 2
awk '$4=="0A" && $2~/:08AE$/{found=1} END{exit !found}' /proc/net/tcp /proc/net/tcp6 \
  && echo "sshd OK" || echo "FAILED — check ~/.tailscale/sshd.log"
```

### Step 6 — Tunnel + watchdog

```bash
PORT=2204  # change this

# Clone repo and generate scripts
[ ! -d ~/hpc-tunnel ] && git clone https://github.com/windx987/hpc-tunnel.git ~/hpc-tunnel
sed "s/\b2200\b/${PORT}/g" ~/hpc-tunnel/reverse-tunnel.sh > ~/reverse-tunnel.sh
sed "s/2200:localhost:2222/${PORT}:localhost:2222/g; s/\b2200\b/${PORT}/g" \
  ~/hpc-tunnel/watchdog-loop.sh > ~/watchdog-loop.sh
chmod +x ~/reverse-tunnel.sh ~/watchdog-loop.sh

pkill -f "reverse-tunnel.sh" 2>/dev/null; pkill -f "watchdog-loop.sh" 2>/dev/null; sleep 1
nohup bash ~/reverse-tunnel.sh >> ~/.tailscale/tunnel.log 2>&1 &
nohup bash ~/watchdog-loop.sh >> ~/.tailscale/watchdog.log 2>&1 &
sleep 10 && tail -5 ~/.tailscale/tunnel.log
```

### Step 7 — Add key to WSL

```bash
# On HPC node
cat ~/.ssh/id_ed25519.pub
```

On **Windows WSL**:
```bash
echo "ssh-ed25519 AAAA...key..." >> ~/.ssh/authorized_keys
ssh-keygen -f ~/.ssh/known_hosts -R '[localhost]:PORT'
```

### Step 8 — Connect script on WSL

```bash
cp ~/hpc-connect-s1.sh ~/hpc-connect-sN.sh
sed -i 's/TUNNEL_PORT="2200"/TUNNEL_PORT="PORT"/' ~/hpc-connect-sN.sh
bash ~/hpc-connect-sN.sh
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `tailscale up` hangs | It printed a URL — open in browser and approve |
| `tailscale status` fails immediately | Daemon is running but not logged in yet — normal. Use `pgrep -f tailscaled` to confirm daemon is up |
| `sshd FAILED — libcrypto.so.4 not found` | Wrong openssh version downloaded (needs OpenSSL 4.x). Pin to `8.9p1` for Ubuntu 22.04 |
| `sshd FAILED — GLIBC_2.38 not found (libwrap)` | Wrong libwrap downloaded. Use `libwrap0_7.6.q-31build2_amd64.deb` specifically |
| `sshd FAILED — libwrap.so.0 not found` | Download libwrap manually (see Step 5 above) |
| `remote port forwarding failed` | Port blocked by Windows Hyper-V — try next even port (2202, 2204…) |
| `Permission denied (publickey)` | WSL key not in HPC `~/.ssh/authorized_keys` |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | Pod replaced; run `ssh-keygen -f ~/.ssh/known_hosts -R '[localhost]:PORT'` |
| Windows sshd blocks WSL sshd port 22 | `powershell.exe -Command "Stop-Service sshd; Set-Service sshd -StartupType Disabled"` |
| Pre-flight SSH hangs | Already handled: `timeout 8` wraps the pre-flight command in `reverse-tunnel.sh` |
| `find -name sshd` picks up wrong file | PAM config `/etc/pam.d/sshd` also named sshd — use `-path '*/sbin/sshd'` |

---

## Node Registry

| Node | Hostname | Tailscale IP | Port | Connect |
|------|----------|--------------|------|---------|
| node-01 | c16g2-01-c9f459586-8d762 | 100.94.243.81 | 2200 | `hpc-connect-s1.sh` |
| node-02 | c16g2-02-dc79477d9-vqs2v | 100.108.215.55 | 2202 | `hpc-connect-s2.sh` |
| node-03 | c16g2-03-9cd7bbf6f-tj9r7 | 100.85.0.124 | 2204 | `hpc-connect-s3.sh` |
| node-04 | c16g2-04-8557dc6cc4-m29gt | 100.124.109.25 | 2206 | `hpc-connect-s4.sh` |

**Next available port: 2208**
