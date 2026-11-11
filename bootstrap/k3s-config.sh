#!/bin/bash
# Writes /etc/rancher/k3s/config.yaml and restarts k3s.
#
# This file was unversioned until 2026-11-10, and that cost an outage.
# flannel-iface was pinned to enp1s0 during the wifi-to-wired migration.
# When the nodes were later bonded, enp1s0 became a bond slave and lost its
# IPv4 -- flannel exited at startup and took k3s with it, roughly every 40
# seconds, on all three nodes at once. Nothing in the repo mentioned the
# dependency, so the bonding change looked unrelated right up until the
# control plane stopped answering.
#
# Keep it here so the next interface change shows up as a diff.
#
#   Usage: k3s-config.sh <node-ip> [flannel-iface]
#
# flannel-iface must name an interface that HOLDS the node IP, not the
# physical NIC underneath it. On a bond that is the bond, not its slaves.

set -euo pipefail

NODE_IP="${1:?usage: $0 <node-ip> [flannel-iface]}"
IFACE="${2:-bond0}"
CONFIG=/etc/rancher/k3s/config.yaml

# Refuse rather than write a config that cannot work. k3s would accept it
# and then crashloop, which is the failure this script exists to prevent.
if ! ip -4 -o addr show "$IFACE" 2>/dev/null | grep -q "inet "; then
  echo "ERROR: $IFACE holds no IPv4 address; flannel would exit at startup" >&2
  echo "       interfaces with an address:" >&2
  ip -4 -o addr show | awk '{print "         " $2 " " $4}' >&2
  exit 1
fi

if ! ip -4 -o addr show "$IFACE" | grep -q "inet ${NODE_IP}/"; then
  echo "ERROR: $NODE_IP is not on $IFACE" >&2
  ip -4 -o addr show "$IFACE" | awk '{print "       " $2 " " $4}' >&2
  exit 1
fi

sudo tee "$CONFIG" >/dev/null <<EOF
write-kubeconfig-mode: "0644"
node-ip: ${NODE_IP}
flannel-iface: ${IFACE}
EOF

echo "wrote $CONFIG:"
sed 's/^/  /' "$CONFIG"

sudo systemctl restart k3s
echo "restarted k3s; give it ~60s, then check: sudo systemctl is-active k3s"
