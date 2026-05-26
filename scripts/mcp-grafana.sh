#!/usr/bin/env bash
# Grafana MCP launcher — works from BOTH environments:
#   - inside a claude-pod (in-cluster): kubectl talks to the API directly
#     via the mounted ServiceAccount, so exec straight into the deployment.
#   - on a local Mac: the cluster API isn't directly reachable (Tailscale
#     shadows the LAN subnet, so Go/kubectl sockets time out), so hop via
#     `ssh homelab` which runs kubectl on a host that can reach it.
#
# Either way it execs the mcp-grafana binary in stdio mode and the MCP
# client speaks to it over stdin/stdout. Referenced by .mcp.json.
set -euo pipefail

EXEC=(kubectl exec -n monitoring -i deploy/mcp-grafana -- /app/mcp-grafana stdio)

if [ -n "${KUBERNETES_SERVICE_HOST:-}" ]; then
  # In-cluster: kubectl works directly.
  exec "${EXEC[@]}"
else
  # Local: reach the cluster through the homelab SSH host.
  exec ssh homelab "${EXEC[@]}"
fi
