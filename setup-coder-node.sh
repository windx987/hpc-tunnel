#!/bin/bash
# One-click setup for ce-kmitl HPC nodes (user: coder, home: /home/coder).
#
# Usage (on the new HPC node):
#   curl -fsSL https://raw.githubusercontent.com/windx987/hpc-tunnel/master/setup-coder-node.sh | bash -s <TUNNEL_PORT>
#
# Example:
#   curl -fsSL .../setup-coder-node.sh | bash -s 3000

set -e

TUNNEL_PORT="${1:?Usage: $0 <TUNNEL_PORT>  (e.g. 3000)}"
WIN=unix@100.76.251.19
USER_HOME="$HOME"
USER_NAME="$(whoami)"
TS="$USER_HOME/tools/tailscale/tailscale"
TSD="$USER_HOME/tools/tailscale/tailscaled"
SOCKET=/tmp/tailscale.sock
LOG_DIR="$USER_HOME/.tailscale"
TS_VERSION=1.98.8

echo "=== [1/7] Tailscale binaries ==="
mkdir -p "$USER_HOME/tools/tailscale" "$LOG_DIR" "$USER_HOME/bin" "$USER_HOME/lib"

if [ -x "$TS" ]; then
  echo "  already installed: $("$TS" version | head -1)"
else
  echo "  downloading tailscale ${TS_VERSION}..."
  cd /tmp
  curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TS_VERSION}_amd64.tgz" -o ts.tgz
  tar -xzf ts.tgz
  cp "tailscale_${TS_VERSION}_amd64/tailscale" "tailscale_${TS_VERSION}_amd64/tailscaled" "$USER_HOME/tools/tailscale/"
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
mkdir -p "$USER_HOME/.ssh"
if ! command -v ssh-keygen > /dev/null 2>&1; then
  echo "  ssh-keygen not found — attempting apt install openssh-client..."
  apt-get install -y openssh-client > /dev/null 2>&1 || \
  sudo apt-get install -y openssh-client > /dev/null 2>&1 || true
fi
if ! command -v ssh-keygen > /dev/null 2>&1; then
  echo "  ERROR: ssh-keygen unavailable. Run: sudo apt-get install -y openssh-client"
  exit 1
fi
if [ ! -f "$USER_HOME/.ssh/ssh_host_ed25519_key" ]; then
  ssh-keygen -t ed25519 -f "$USER_HOME/.ssh/ssh_host_ed25519_key" -N "" -q
  echo "  generated host ed25519 key"
fi
if [ ! -f "$USER_HOME/.ssh/ssh_host_rsa_key" ]; then
  ssh-keygen -t rsa -b 4096 -f "$USER_HOME/.ssh/ssh_host_rsa_key" -N "" -q
  echo "  generated host rsa key"
fi
if [ ! -f "$USER_HOME/.ssh/id_ed25519" ]; then
  ssh-keygen -t ed25519 -f "$USER_HOME/.ssh/id_ed25519" -N "" -C "${USER_NAME}@$(hostname)" -q
  echo "  generated outbound key"
fi
echo "  OK"

echo ""
echo "=== [4/7] sshd_config ==="
cat > "$USER_HOME/.ssh/sshd_config" << EOF
Port 2222
HostKey $USER_HOME/.ssh/ssh_host_ed25519_key
HostKey $USER_HOME/.ssh/ssh_host_rsa_key
AuthorizedKeysFile $USER_HOME/.ssh/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
AllowUsers $USER_NAME
PrintMotd no
LogLevel DEBUG3
EOF

if [ -x /usr/lib/openssh/sftp-server ]; then
  echo "Subsystem sftp /usr/lib/openssh/sftp-server" >> "$USER_HOME/.ssh/sshd_config"
fi

WSL_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKN4KumeqrlTI2Yyj14p8mrGdUNrVLldYZ9dZ5jp7drO terawat.cc@gmail.com"
touch "$USER_HOME/.ssh/authorized_keys"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
grep -qF "$WSL_KEY" "$USER_HOME/.ssh/authorized_keys" || echo "$WSL_KEY" >> "$USER_HOME/.ssh/authorized_keys"
echo "  OK"

echo ""
echo "=== [5/7] sshd ==="
SSHD=/usr/sbin/sshd
[ -x "$SSHD" ] || SSHD="$USER_HOME/bin/sshd"

if [ ! -x "$SSHD" ]; then
  echo "  sshd not found — attempting apt install..."
  if apt-get install -y openssh-server > /dev/null 2>&1; then
    SSHD=/usr/sbin/sshd
  else
    echo "  apt failed — downloading sshd + libwrap from Ubuntu archive..."
    _download_sshd() {
      local tmpdir; tmpdir=$(mktemp -d)
      local os_ver; os_ver=$(grep -oP '(?<=VERSION_ID=")[^"]+' /etc/os-release 2>/dev/null || echo "22.04")
      local pkg_filter='openssh-server_[^"]+amd64\.deb'
      [[ "$os_ver" == "22.04" ]] && pkg_filter='openssh-server_8\.9p1[^"]+amd64\.deb'
      local pkg; pkg=$(curl -s "http://archive.ubuntu.com/ubuntu/pool/main/o/openssh/" \
        | grep -oP "$pkg_filter" | tail -1)
      [ -z "$pkg" ] && { echo "  ERROR: could not find openssh-server package"; return 1; }
      curl -fsSL "http://archive.ubuntu.com/ubuntu/pool/main/o/openssh/$pkg" -o "$tmpdir/openssh.deb" || return 1
      dpkg -x "$tmpdir/openssh.deb" "$tmpdir/openssh-ext" || return 1
      local sshd_src; sshd_src=$(find "$tmpdir/openssh-ext" -path '*/sbin/sshd' -type f | head -1)
      [ -z "$sshd_src" ] && { echo "  ERROR: sshd not found in package"; return 1; }
      cp "$sshd_src" "$USER_HOME/bin/sshd" && chmod +x "$USER_HOME/bin/sshd" || return 1
      local lwpkg="libwrap0_7.6.q-31build2_amd64.deb"
      curl -fsSL "http://archive.ubuntu.com/ubuntu/pool/main/t/tcp-wrappers/$lwpkg" -o "$tmpdir/libwrap.deb" 2>/dev/null
      dpkg -x "$tmpdir/libwrap.deb" "$tmpdir/libwrap-ext" 2>/dev/null
      find "$tmpdir/libwrap-ext" -name 'libwrap.so*' | xargs -I{} cp {} "$USER_HOME/lib/" 2>/dev/null || true
      rm -rf "$tmpdir"
    }
    if ! _download_sshd; then
      echo "  ERROR: could not obtain sshd binary."
      exit 1
    fi
    SSHD="$USER_HOME/bin/sshd"
    echo "  downloaded sshd from Ubuntu archive"
  fi
fi

if ldd "$SSHD" 2>&1 | grep -q "libwrap.so.0 => not found"; then
  echo "  libwrap.so.0 missing — checking $USER_HOME/lib..."
  if [ ! -f "$USER_HOME/lib/libwrap.so.0" ]; then
    echo "  downloading libwrap from Ubuntu archive..."
    _lwpkg="libwrap0_7.6.q-31build2_amd64.deb"
    _lwtmp=$(mktemp -d)
    curl -fsSL "http://archive.ubuntu.com/ubuntu/pool/main/t/tcp-wrappers/$_lwpkg" -o "$_lwtmp/libwrap.deb"
    dpkg -x "$_lwtmp/libwrap.deb" "$_lwtmp/libwrap-ext" 2>/dev/null
    find "$_lwtmp/libwrap-ext" -name 'libwrap.so*' | xargs -I{} cp {} "$USER_HOME/lib/" 2>/dev/null || true
    rm -rf "$_lwtmp"
  fi
  export LD_LIBRARY_PATH="$USER_HOME/lib"
fi

sed -i '/PrivilegeSeparation/d' "$USER_HOME/.ssh/sshd_config"

if ! "$SSHD" -t -f "$USER_HOME/.ssh/sshd_config" 2>/dev/null; then
  echo "  ERROR: sshd config test failed"
  "$SSHD" -t -f "$USER_HOME/.ssh/sshd_config"
  exit 1
fi

pkill -f "sshd.*sshd_config" 2>/dev/null || true
sleep 1
if [ -n "$LD_LIBRARY_PATH" ]; then
  nohup env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" "$SSHD" -f "$USER_HOME/.ssh/sshd_config" >> "$LOG_DIR/sshd.log" 2>&1 &
else
  nohup "$SSHD" -f "$USER_HOME/.ssh/sshd_config" >> "$LOG_DIR/sshd.log" 2>&1 &
fi
sleep 2

if awk '$4 == "0A" && $2 ~ /:08AE$/ {found=1} END {exit !found}' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
  echo "  OK — listening on :2222"
else
  echo "  ERROR: sshd not listening. Check $LOG_DIR/sshd.log"
  exit 1
fi

echo ""
echo "=== [6/7] Tunnel scripts (port ${TUNNEL_PORT}) ==="

cat > "$USER_HOME/reverse-tunnel.sh" << RTEOF
#!/bin/bash
LOG=$USER_HOME/.tailscale/tunnel.log
WIN=unix@100.76.251.19
PROXY="$USER_HOME/tools/tailscale/tailscale --socket=/tmp/tailscale.sock nc %h %p"
SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o "ProxyCommand=\$PROXY")
echo "\$(date) tunnel loop starting (PID \$\$)" >> "\$LOG"
while true; do
  timeout 8 ssh "\${SSH_OPTS[@]}" "$WIN" "
    pid=\$(ss -tlnp sport = \":${TUNNEL_PORT}\" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1)
    [ -n \"\$pid\" ] && kill \"\$pid\" 2>/dev/null
  " >> "\$LOG" 2>&1
  ssh "\${SSH_OPTS[@]}" -N -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=60 -o ServerAliveCountMax=5 -o TCPKeepAlive=yes \
    -R ${TUNNEL_PORT}:localhost:2222 "$WIN" >> "\$LOG" 2>&1
  echo "\$(date) tunnel exited, retrying in 10s" >> "\$LOG"
  sleep 10
done
RTEOF

cat > "$USER_HOME/watchdog-loop.sh" << WDEOF
#!/bin/bash
LOG=$USER_HOME/.tailscale/watchdog.log
TS=$USER_HOME/tools/tailscale/tailscale
TSD=$USER_HOME/tools/tailscale/tailscaled
SOCKET=/tmp/tailscale.sock
while true; do
  if ! "\$TS" --socket="\$SOCKET" status > /dev/null 2>&1; then
    echo "\$(date) tailscaled down, restarting" >> "\$LOG"
    pkill -f tailscaled; sleep 1
    nohup "\$TSD" --tun=userspace-networking --state=$USER_HOME/.tailscale/state --socket="\$SOCKET" >> $USER_HOME/.tailscale/tailscaled.log 2>&1 &
    sleep 8
  fi
  if ! awk '\$4=="0A" && \$2~/:08AE\$/{found=1} END{exit !found}' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
    echo "\$(date) sshd down, restarting" >> "\$LOG"
    pkill -f "sshd.*sshd_config"; sleep 1
    nohup env LD_LIBRARY_PATH=$USER_HOME/lib $USER_HOME/bin/sshd -f $USER_HOME/.ssh/sshd_config >> $USER_HOME/.tailscale/sshd.log 2>&1 &
    sleep 3
  fi
  if ! pgrep -f reverse-tunnel > /dev/null; then
    echo "\$(date) tunnel down, restarting" >> "\$LOG"
    nohup bash $USER_HOME/reverse-tunnel.sh >> $USER_HOME/.tailscale/tunnel.log 2>&1 &
    sleep 5
  fi
  sleep 30
done
WDEOF

chmod +x "$USER_HOME/reverse-tunnel.sh" "$USER_HOME/watchdog-loop.sh"
echo "  OK — using port ${TUNNEL_PORT}"

echo ""
echo "=== [7/7] Starting tunnel + watchdog ==="
pkill -f "reverse-tunnel.sh" 2>/dev/null || true
pkill -f "watchdog-loop.sh" 2>/dev/null || true
sleep 1
nohup bash "$USER_HOME/reverse-tunnel.sh" >> "$LOG_DIR/tunnel.log" 2>&1 &
nohup bash "$USER_HOME/watchdog-loop.sh" >> "$LOG_DIR/watchdog.log" 2>&1 &
sleep 8

echo ""
echo "================================================================"
echo "DONE. Tunnel targeting Windows:${TUNNEL_PORT} → HPC:2222"
echo "User: ${USER_NAME}  Home: ${USER_HOME}"
echo ""
echo "ADD THIS KEY TO Windows WSL ~/.ssh/authorized_keys:"
cat "$USER_HOME/.ssh/id_ed25519.pub"
echo ""
echo "ON WINDOWS WSL, create the connect script:"
echo "  cp ~/hpc-connect-s1.sh ~/hpc-connect-sX.sh"
echo "  sed -i 's/TUNNEL_PORT=\"2200\"/TUNNEL_PORT=\"${TUNNEL_PORT}\"/' ~/hpc-connect-sX.sh"
echo "  # Also update the SSH user if needed:"
echo "  sed -i 's/glider@localhost/${USER_NAME}@localhost/' ~/hpc-connect-sX.sh"
echo ""
echo "Tunnel log:"
tail -5 "$LOG_DIR/tunnel.log"
echo "================================================================"
