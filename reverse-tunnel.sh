#!/bin/bash
# Reverse SSH tunnel: Windows:2200 → HPC:localhost:2222 (sshd)
# Connect from Windows with: bash ~/hpc-connect-s1.sh  (ssh -p 2200 glider@localhost)
#
# Self-healing loop:
#   1. Pre-flight: kill only the sshd-session holding port 2200 on Windows
#      (targeted kill — safe for multi-node: does NOT touch other nodes' ports)
#   2. Run the tunnel with ExitOnForwardFailure=yes — if the bind fails or the
#      transport dies, ssh exits and the loop retries after 10s

LOG=/home/glider/.tailscale/tunnel.log
WIN=unix@100.76.251.19
PROXY="/home/glider/tools/tailscale/tailscale --socket=/tmp/tailscale.sock nc %h %p"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o ConnectTimeout=15
  -o "ProxyCommand=$PROXY"
)

echo "$(date) tunnel loop starting (PID $$)" >> "$LOG"

while true; do
  # Pre-flight: kill only the sshd-session holding port 2200 on Windows
  # timeout 8: prevents indefinite hang on nodes where first SSH stalls
  timeout 8 ssh "${SSH_OPTS[@]}" "$WIN" '
    pid=$(ss -tlnp sport = ":2200" 2>/dev/null | grep -oP "pid=\K[0-9]+" | head -1)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  ' >> "$LOG" 2>&1

  ssh "${SSH_OPTS[@]}" -N \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=5 \
    -o TCPKeepAlive=yes \
    -R 2200:localhost:2222 \
    "$WIN" >> "$LOG" 2>&1

  echo "$(date) tunnel exited, retrying in 10s" >> "$LOG"
  sleep 10
done
