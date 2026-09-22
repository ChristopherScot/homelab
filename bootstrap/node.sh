#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Check if the necessary arguments are provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <MASTER_IP> <TOKEN>"
    exit 1
fi

MASTER_IP=$1
TOKEN=$2

# Install k3s and join the existing cluster as a controller/master using internal etcd
echo "Joining the existing k3s cluster as a controller/master using internal etcd..."
curl -sfL https://get.k3s.io | K3S_URL=https://$MASTER_IP:6443 K3S_TOKEN=$TOKEN sh -s - server --disable traefik --disable servicelb

# metrics-server is intentionally not disabled here - see primary.sh for
# why we stopped replacing it with a Helm install.
#
# This node's own warning was the thing that came true. Every server node
# runs the addon controller, so one node missing the flag reintroduces the
# addon for the whole cluster. On 2026-09-22 pop-os had the flag and the
# manifests removed, while node1 and node2 had neither - so k3s kept
# re-applying its metrics-server, the Helm Service could not select it,
# and `kubectl top` was down with v1beta1.metrics.k8s.io Available=False.
#
# Running only k3s's copy removes the race entirely.
for want in traefik servicelb; do
  if ! systemctl cat k3s.service 2>/dev/null | grep -q "'$want'"; then
    echo "WARNING: --disable $want did not reach /etc/systemd/system/k3s.service." >&2
    echo "  Fix ExecStart, remove /var/lib/rancher/k3s/server/manifests/$want*," >&2
    echo "  then: sudo systemctl daemon-reload && sudo systemctl restart k3s" >&2
  fi
done

# Wait for k3s to be up and running
echo "Waiting for k3s to be up and running..."
sleep 30

# Set KUBECONFIG environment variable
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Set permissions for kubeconfig file
echo "Setting permissions for kubeconfig file..."
sudo chmod 644 /etc/rancher/k3s/k3s.yaml

echo "Node has successfully joined the k3s cluster as a controller/master!"