#!/bin/bash
# Run this on Windows WSL to connect to the HPC node via reverse tunnel.
# Requires: the reverse tunnel to be running on the HPC (reverse-tunnel.sh)

HPC_USER="glider"
TUNNEL_PORT="2200"

# Check if tunnel is up
if ! ss -tlnp 2>/dev/null | grep -q ":${TUNNEL_PORT}" && \
   ! netstat -tnlp 2>/dev/null | grep -q ":${TUNNEL_PORT}"; then
  echo "Tunnel not detected on port ${TUNNEL_PORT}."
  echo "Make sure reverse-tunnel.sh is running on the HPC."
  echo "Run on HPC: nohup bash ~/reverse-tunnel.sh > ~/.tailscale/tunnel.log 2>&1 &"
  exit 1
fi

# Clear cached host key — HPC pod key changes on restarts
ssh-keygen -R "[localhost]:${TUNNEL_PORT}" -f ~/.ssh/known_hosts 2>/dev/null
ssh-keygen -R "[127.0.0.1]:${TUNNEL_PORT}" -f ~/.ssh/known_hosts 2>/dev/null

echo "Connecting to HPC (${HPC_USER}@localhost:${TUNNEL_PORT})..."
ssh -p "${TUNNEL_PORT}" \
  -o "StrictHostKeyChecking accept-new" \
  -o "ServerAliveInterval 60" \
  -o "ServerAliveCountMax 3" \
  "${HPC_USER}@localhost"
