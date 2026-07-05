#!/bin/bash
# Run this after every pod restart to bring SSH access back up.
# Also safe to re-run at any time to fix a stuck connection.

TAILSCALE=/home/glider/tools/tailscale/tailscale
TAILSCALED=/home/glider/tools/tailscale/tailscaled
SOCKET=/tmp/tailscale.sock
LOG_DIR=/home/glider/.tailscale

mkdir -p "$LOG_DIR"

echo "[1/7] Starting tailscaled..."
if ! pgrep -f tailscaled > /dev/null; then
  nohup "$TAILSCALED" \
    --tun=userspace-networking \
    --state="$LOG_DIR/state" \
    --socket="$SOCKET" \
    >> "$LOG_DIR/tailscaled.log" 2>&1 &
  sleep 5
else
  echo "  tailscaled already running (PID $(pgrep -f tailscaled))"
fi

if ! "$TAILSCALE" --socket="$SOCKET" status > /dev/null 2>&1; then
  echo "  ERROR: tailscaled not responding. Check $LOG_DIR/tailscaled.log"
  exit 1
fi
echo "  OK — $("$TAILSCALE" --socket="$SOCKET" ip 2>/dev/null | head -1)"

echo "[2/7] Starting sshd..."
if [ ! -x /usr/sbin/sshd ]; then
  echo "  sshd binary missing (pod restart) — reinstalling openssh-server..."
  sudo apt-get update -qq
  sudo apt-get install -y openssh-server > /dev/null
fi
if ! pgrep -f "sshd.*sshd_config" > /dev/null; then
  nohup /usr/sbin/sshd -f ~/.ssh/sshd_config >> "$LOG_DIR/sshd.log" 2>&1 &
  sleep 1
else
  echo "  sshd already running (PID $(pgrep -f 'sshd.*sshd_config'))"
fi

if ! awk '$4 == "0A" && $2 ~ /:08AE$/ {found=1} END {exit !found}' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
  echo "  ERROR: sshd not listening on port 2222"
  exit 1
fi
echo "  OK — listening on :2222"

echo "[3/7] Configuring Tailscale serve..."
"$TAILSCALE" --socket="$SOCKET" serve reset 2>/dev/null || true
sleep 1
"$TAILSCALE" --socket="$SOCKET" serve --bg --tcp=2222 2222 2>/dev/null
sleep 2

if "$TAILSCALE" --socket="$SOCKET" serve status 2>/dev/null | grep -q '2222'; then
  echo "  OK — port 2222 exposed on Tailscale"
else
  echo "  WARNING: serve config may have failed (non-critical)"
fi

echo "[4/7] Starting HTTPS proxy..."
if ! pgrep -f "https-proxy.py" > /dev/null; then
  python3 /home/glider/https-proxy.py > "$LOG_DIR/proxy.log" 2>&1 &
  sleep 1
fi
echo "  OK — proxy on :18080"

echo "[5/7] Starting VS Code tunnel..."
if ! pgrep -f "vscode/code tunnel" > /dev/null; then
  HTTPS_PROXY=http://127.0.0.1:18080 HTTP_PROXY=http://127.0.0.1:18080 \
    /home/glider/bin/vscode/code tunnel --accept-server-license-terms --name hpc-glider \
    > "$LOG_DIR/vscode-tunnel.log" 2>&1 &
  echo "  OK — tunnel starting (log: ~/.tailscale/vscode-tunnel.log)"
else
  echo "  VS Code tunnel already running (PID $(pgrep -f 'vscode/code tunnel'))"
fi

echo "[6/7] Starting reverse tunnel..."
# Kill any old tunnel loops / autossh / stray forwards so exactly one loop runs
pkill -f "reverse-tunnel.sh" 2>/dev/null
pkill -f "autossh" 2>/dev/null
pkill -f "ssh .*-R 2200:localhost:2222" 2>/dev/null
sleep 1
nohup bash /home/glider/reverse-tunnel.sh >> "$LOG_DIR/tunnel.log" 2>&1 &
echo "  OK — tunnel loop running (PID $!)"

echo "[7/7] Starting watchdog..."
# Kill any old watchdog so a stale instance can never linger
pkill -f "watchdog-loop.sh" 2>/dev/null
sleep 1
nohup bash /home/glider/watchdog-loop.sh >> "$LOG_DIR/watchdog.log" 2>&1 &
echo "  OK — watchdog running (PID $!)"

echo ""
echo "Done."
echo "  Primary (reverse tunnel): ssh -p 2200 glider@localhost  [on Windows WSL]"
echo "  Fallback (tailscale):     ssh -p 2222 glider@$("$TAILSCALE" --socket="$SOCKET" ip 2>/dev/null | head -1)"
