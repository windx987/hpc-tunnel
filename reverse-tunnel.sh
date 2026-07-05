#!/bin/bash
# Reverse SSH tunnel: Windows:2200 → HPC:localhost:2222 (sshd)
# Connect from Windows with: bash ~/hpc-connect.sh  (ssh -p 2200 glider@localhost)
#
# Self-healing loop:
#   1. Pre-flight: kill stale unix sshd-sessions on Windows so port 2200 is free
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
  # Pre-flight: on Windows, kill every unix sshd-session that is not an
  # ancestor of this cleanup command's own session (frees stale port 2200)
  ssh "${SSH_OPTS[@]}" "$WIN" '
    own=$$; keep="";
    while [ "$own" != 1 ] && [ -r /proc/$own/stat ]; do
      keep="$keep $own"
      own=$(awk "{print \$4}" /proc/$own/stat)
    done
    for p in $(pgrep -u unix sshd-session); do
      echo "$keep" | grep -qw "$p" || kill "$p" 2>/dev/null
    done' >> "$LOG" 2>&1

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
