#!/bin/bash
# Watchdog: keeps tailscaled, sshd (:2222), and the reverse tunnel loop alive.
# All checks are idempotent — it only starts things that are down.

TS=/home/glider/tools/tailscale/tailscale
TAILSCALED=/home/glider/tools/tailscale/tailscaled
SK=/tmp/tailscale.sock
LOG=/home/glider/.tailscale/watchdog.log

echo "$(date) watchdog started (PID $$)" >> "$LOG"

while true; do
  sleep 60

  # 1. tailscaled
  if ! "$TS" --socket="$SK" status > /dev/null 2>&1; then
    echo "$(date) tailscaled down — restarting" >> "$LOG"
    nohup "$TAILSCALED" --tun=userspace-networking \
      --state=/home/glider/.tailscale/state \
      --socket="$SK" \
      >> /home/glider/.tailscale/tailscaled.log 2>&1 &
    sleep 8
  fi

  # 2. sshd listening on 2222 (0x08AE), state 0A = LISTEN in /proc/net/tcp
  if ! awk '$4 == "0A" && $2 ~ /:08AE$/ {found=1} END {exit !found}' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
    echo "$(date) sshd down — restarting" >> "$LOG"
    if [ ! -x /usr/sbin/sshd ]; then
      echo "$(date) sshd binary missing (pod restart) — reinstalling" >> "$LOG"
      sudo apt-get update -qq >> "$LOG" 2>&1
      sudo apt-get install -y openssh-server >> "$LOG" 2>&1
    fi
    nohup /usr/sbin/sshd -f /home/glider/.ssh/sshd_config >> /home/glider/.tailscale/sshd.log 2>&1 &
    sleep 2
  fi

  # 3. reverse tunnel loop
  if ! pgrep -f "reverse-tunnel.sh" > /dev/null; then
    echo "$(date) tunnel loop down — restarting" >> "$LOG"
    nohup bash /home/glider/reverse-tunnel.sh >> /home/glider/.tailscale/tunnel.log 2>&1 &
  fi

  # 4. end-to-end probe: the tunnel ssh can stall (Tailscale userspace freeze)
  # while still looking alive for up to 5 min (keepalive 60x5). Probe the SSH
  # banner through Windows:2200 on a fresh connection; if it doesn't answer,
  # kill the tunnel ssh so the loop reconnects with pre-flight cleanup.
  TUNNEL_PID=$(pgrep -f "ssh .*-R 2200:localhost:2222" | head -1)
  if [ -n "$TUNNEL_PID" ]; then
    AGE=$(ps -o etimes= -p "$TUNNEL_PID" 2>/dev/null | tr -d ' ')
    if [ "${AGE:-0}" -gt 90 ]; then
      if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes \
          -o "ProxyCommand=$TS --socket=$SK nc %h %p" \
          unix@100.76.251.19 \
          'timeout 5 bash -c "read -r b < /dev/tcp/localhost/2200; echo \$b" 2>/dev/null | grep -q SSH' \
          > /dev/null 2>&1; then
        echo "$(date) tunnel probe failed (stalled stream) — killing tunnel ssh $TUNNEL_PID" >> "$LOG"
        kill -9 "$TUNNEL_PID" 2>/dev/null
      fi
    fi
  fi
done
