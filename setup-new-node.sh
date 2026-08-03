#!/bin/bash
# One-click setup for a new HPC node.
#
# Usage (on the new HPC node):
#   bash setup-new-node.sh <TUNNEL_PORT>
#
# Example:
#   bash setup-new-node.sh 2202
#
# After this script completes:
#   1. Copy the printed public key into Windows WSL ~/.ssh/authorized_keys
#   2. On Windows WSL: cp ~/hpc-connect-s1.sh ~/hpc-connect-sN.sh
#                      sed -i 's/2200/<TUNNEL_PORT>/' ~/hpc-connect-sN.sh

set -e

TUNNEL_PORT="${1:?Usage: $0 <TUNNEL_PORT>  (e.g. 2202)}"
WIN=unix@100.76.251.19
TS=/home/glider/tools/tailscale/tailscale
TSD=/home/glider/tools/tailscale/tailscaled
SOCKET=/tmp/tailscale.sock
LOG_DIR=/home/glider/.tailscale
TS_VERSION=1.98.8

echo "=== [1/7] Tailscale binaries ==="
mkdir -p ~/tools/tailscale "$LOG_DIR" ~/bin ~/lib

if [ -x "$TS" ]; then
  echo "  already installed: $("$TS" version | head -1)"
else
  echo "  downloading tailscale ${TS_VERSION}..."
  cd /tmp
  curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TS_VERSION}_amd64.tgz" -o ts.tgz
  tar -xzf ts.tgz
  cp "tailscale_${TS_VERSION}_amd64/tailscale" "tailscale_${TS_VERSION}_amd64/tailscaled" ~/tools/tailscale/
  chmod +x "$TS" "$TSD"
  echo "  installed: $("$TS" version | head -1)"
fi

echo ""
echo "=== [2/7] tailscaled ==="
if "$TS" --socket="$SOCKET" status > /dev/null 2>&1; then
  echo "  already running (IP: $("$TS" --socket="$SOCKET" ip 2>/dev/null | head -1))"
else
  pkill -f tailscaled 2>/dev/null || true
  sleep 1
  nohup "$TSD" \
    --tun=userspace-networking \
    --state="$LOG_DIR/state" \
    --socket="$SOCKET" \
    >> "$LOG_DIR/tailscaled.log" 2>&1 &
  sleep 6
  # Check tailscaled is responsive (pgrep), not tailscale status (fails when not logged in)
  if ! pgrep -f tailscaled > /dev/null 2>&1; then
    echo "  ERROR: tailscaled not running. Check $LOG_DIR/tailscaled.log"
    exit 1
  fi
  echo "  OK"
fi

if ! "$TS" --socket="$SOCKET" ip > /dev/null 2>&1; then
  echo ""
  echo "  Tailscale not authenticated. Open the URL below in your browser:"
  "$TS" --socket="$SOCKET" up
  echo "  (After auth, re-run this script to continue.)"
  exit 0
fi
echo "  Tailscale IP: $("$TS" --socket="$SOCKET" ip 2>/dev/null | head -1)"

echo ""
echo "=== [3/7] SSH keys ==="
mkdir -p ~/.ssh
if [ ! -f ~/.ssh/ssh_host_ed25519_key ]; then
  ssh-keygen -t ed25519 -f ~/.ssh/ssh_host_ed25519_key -N "" -q
  echo "  generated host ed25519 key"
fi
if [ ! -f ~/.ssh/ssh_host_rsa_key ]; then
  ssh-keygen -t rsa -b 4096 -f ~/.ssh/ssh_host_rsa_key -N "" -q
  echo "  generated host rsa key"
fi
if [ ! -f ~/.ssh/id_ed25519 ]; then
  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "glider@$(hostname)" -q
  echo "  generated outbound key"
fi
echo "  OK"

echo ""
echo "=== [4/7] sshd_config ==="
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

# Add sftp subsystem only if the binary exists
if [ -x /usr/lib/openssh/sftp-server ]; then
  echo "Subsystem sftp /usr/lib/openssh/sftp-server" >> ~/.ssh/sshd_config
fi

# Add WSL's public key
WSL_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKN4KumeqrlTI2Yyj14p8mrGdUNrVLldYZ9dZ5jp7drO terawat.cc@gmail.com"
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
grep -qF "$WSL_KEY" ~/.ssh/authorized_keys || echo "$WSL_KEY" >> ~/.ssh/authorized_keys
echo "  OK"

echo ""
echo "=== [5/7] sshd ==="
SSHD=/usr/sbin/sshd
if [ ! -x "$SSHD" ]; then
  SSHD=~/bin/sshd
fi

if [ ! -x "$SSHD" ]; then
  echo "  sshd not found — attempting apt install..."
  if apt-get install -y openssh-server > /dev/null 2>&1; then
    SSHD=/usr/sbin/sshd
  else
    echo "  apt failed — downloading sshd + libwrap from Ubuntu archive..."
    _download_sshd() {
      local tmpdir; tmpdir=$(mktemp -d)
      # openssh-server
      local pkg; pkg=$(curl -s "http://archive.ubuntu.com/ubuntu/pool/main/o/openssh/" \
        | grep -oP 'openssh-server_[^"]+amd64\.deb' | tail -1)
      [ -z "$pkg" ] && { echo "  ERROR: could not find openssh-server package"; return 1; }
      curl -fsSL "http://archive.ubuntu.com/ubuntu/pool/main/o/openssh/$pkg" -o "$tmpdir/openssh.deb" || return 1
      # dpkg -x handles zstd/xz/gz natively; much more reliable than ar+tar
      dpkg -x "$tmpdir/openssh.deb" "$tmpdir/openssh-ext" || return 1
      local sshd_src; sshd_src=$(find "$tmpdir/openssh-ext" -name sshd -type f | head -1)
      [ -z "$sshd_src" ] && { echo "  ERROR: sshd not found in package"; return 1; }
      cp "$sshd_src" ~/bin/sshd && chmod +x ~/bin/sshd || return 1
      # libwrap0
      local lwpkg; lwpkg=$(curl -s "http://archive.ubuntu.com/ubuntu/pool/main/t/tcp-wrappers/" \
        | grep -oP 'libwrap0_[^"]+amd64\.deb' | tail -1)
      if [ -n "$lwpkg" ]; then
        curl -fsSL "http://archive.ubuntu.com/ubuntu/pool/main/t/tcp-wrappers/$lwpkg" -o "$tmpdir/libwrap.deb" 2>/dev/null
        dpkg -x "$tmpdir/libwrap.deb" "$tmpdir/libwrap-ext" 2>/dev/null
        find "$tmpdir/libwrap-ext" -name 'libwrap.so*' | xargs -I{} cp {} ~/lib/ 2>/dev/null || true
      fi
      rm -rf "$tmpdir"
    }
    if ! _download_sshd; then
      echo "  ERROR: could not obtain sshd binary. Set NODE01_IP=<ip> and re-run."
      exit 1
    fi
    SSHD=~/bin/sshd
    echo "  downloaded sshd from Ubuntu archive"
  fi
fi

# Check for missing libwrap (common on stripped containers)
if ldd "$SSHD" 2>&1 | grep -q "libwrap.so.0 => not found"; then
  echo "  libwrap.so.0 missing — checking ~/lib..."
  if [ ! -f ~/lib/libwrap.so.0 ]; then
    echo "  downloading libwrap from Ubuntu archive..."
    lwpkg=$(curl -s "http://archive.ubuntu.com/ubuntu/pool/main/t/tcp-wrappers/" \
      | grep -oP 'libwrap0_[^"]+amd64\.deb' | tail -1)
    tmpdir=$(mktemp -d)
    curl -fsSL "http://archive.ubuntu.com/ubuntu/pool/main/t/tcp-wrappers/$lwpkg" -o "$tmpdir/libwrap.deb"
    dpkg -x "$tmpdir/libwrap.deb" "$tmpdir/libwrap-ext" 2>/dev/null
    find "$tmpdir/libwrap-ext" -name 'libwrap.so*' | xargs -I{} cp {} ~/lib/ 2>/dev/null || true
    rm -rf "$tmpdir"
  fi
  export LD_LIBRARY_PATH=~/lib
fi

# Remove PrivilegeSeparation if present (removed in newer OpenSSH)
sed -i '/PrivilegeSeparation/d' ~/.ssh/sshd_config

if ! "$SSHD" -t -f ~/.ssh/sshd_config 2>/dev/null; then
  echo "  ERROR: sshd config test failed"
  "$SSHD" -t -f ~/.ssh/sshd_config
  exit 1
fi

pkill -f "sshd.*sshd_config" 2>/dev/null || true
sleep 1
if [ -n "$LD_LIBRARY_PATH" ]; then
  nohup env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" "$SSHD" -f ~/.ssh/sshd_config >> "$LOG_DIR/sshd.log" 2>&1 &
else
  nohup "$SSHD" -f ~/.ssh/sshd_config >> "$LOG_DIR/sshd.log" 2>&1 &
fi
sleep 2

# Verify listening (0x08AE = 2222)
if awk '$4 == "0A" && $2 ~ /:08AE$/ {found=1} END {exit !found}' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
  echo "  OK — listening on :2222"
else
  echo "  ERROR: sshd not listening. Check $LOG_DIR/sshd.log"
  exit 1
fi

echo ""
echo "=== [6/7] Tunnel scripts (port ${TUNNEL_PORT}) ==="
if [ ! -d ~/hpc-tunnel ]; then
  git clone https://github.com/windx987/hpc-tunnel.git ~/hpc-tunnel
fi

sed "s/\b2200\b/${TUNNEL_PORT}/g" \
  ~/hpc-tunnel/reverse-tunnel.sh > ~/reverse-tunnel.sh

sed "s/2200:localhost:2222/${TUNNEL_PORT}:localhost:2222/g; s/\b2200\b/${TUNNEL_PORT}/g" \
  ~/hpc-tunnel/watchdog-loop.sh > ~/watchdog-loop.sh

chmod +x ~/reverse-tunnel.sh ~/watchdog-loop.sh
echo "  OK — using port ${TUNNEL_PORT}"

echo ""
echo "=== [7/7] Starting tunnel + watchdog ==="
pkill -f "reverse-tunnel.sh" 2>/dev/null || true
pkill -f "watchdog-loop.sh" 2>/dev/null || true
sleep 1
nohup bash ~/reverse-tunnel.sh >> "$LOG_DIR/tunnel.log" 2>&1 &
nohup bash ~/watchdog-loop.sh >> "$LOG_DIR/watchdog.log" 2>&1 &
sleep 8

echo ""
echo "================================================================"
echo "DONE. Tunnel targeting Windows:${TUNNEL_PORT} → HPC:2222"
echo ""
echo "ADD THIS KEY TO Windows WSL ~/.ssh/authorized_keys:"
cat ~/.ssh/id_ed25519.pub
echo ""
echo "ON WINDOWS WSL, create the connect script:"
echo "  cp ~/hpc-connect-s1.sh ~/hpc-connect-sX.sh"
echo "  sed -i 's/TUNNEL_PORT=\"2200\"/TUNNEL_PORT=\"${TUNNEL_PORT}\"/' ~/hpc-connect-sX.sh"
echo ""
echo "Tunnel log:"
tail -5 "$LOG_DIR/tunnel.log"
echo "================================================================"
