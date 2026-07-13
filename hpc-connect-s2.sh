#!/bin/bash
HPC_USER="glider"
TUNNEL_PORT="2202"

if ! ss -tlnp 2>/dev/null | grep -q ":${TUNNEL_PORT}"; then
  echo "Tunnel not detected on port ${TUNNEL_PORT}."
  echo "Run on node-02: nohup bash ~/reverse-tunnel.sh >> ~/.tailscale/tunnel.log 2>&1 &"
  exit 1
fi

ssh-keygen -R "[localhost]:${TUNNEL_PORT}" -f ~/.ssh/known_hosts 2>/dev/null
ssh-keygen -R "[127.0.0.1]:${TUNNEL_PORT}" -f ~/.ssh/known_hosts 2>/dev/null

echo "Connecting to HPC A100 node (${HPC_USER}@localhost:${TUNNEL_PORT})..."
ssh -p "${TUNNEL_PORT}" \
  -o "StrictHostKeyChecking accept-new" \
  -o "ServerAliveInterval 60" \
  -o "ServerAliveCountMax 3" \
  "${HPC_USER}@localhost"
