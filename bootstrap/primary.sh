#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Install k3s with Traefik, Service Load Balancer, and metrics-server disabled,
# and use etcd as the datastore. metrics-server is replaced by an ArgoCD-managed
# Helm install (see app-of-apps/apps/metrics-server.yaml) which adds the
# --kubelet-insecure-tls flag k3s's bundled version is missing.
echo "Installing k3s with Traefik, Service Load Balancer, and metrics-server disabled, using etcd as the datastore..."
curl -sfL https://get.k3s.io | sh -s - server --disable traefik --disable servicelb --disable metrics-server --cluster-init

# Wait for k3s to be up and running
echo "Waiting for k3s to be up and running..."
sleep 30

# Set KUBECONFIG environment variable
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Set permissions for kubeconfig file
echo "Setting permissions for kubeconfig file..."
sudo chmod 644 /etc/rancher/k3s/k3s.yaml

# MetalLB is installed and configured by ArgoCD via app-of-apps/apps/metallb.yaml.
# It will not be available until ArgoCD finishes syncing.

# Install NGINX Ingress Controller. Pinning a release tag (vs main) so future
# bootstraps don't drift on what they install.
echo "Installing NGINX Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/cloud/deploy.yaml

# Wait for NGINX Ingress Controller to be up and running
echo "Waiting for NGINX Ingress Controller to be up and running..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s

# Enable risky annotations so arr-stack ingresses' auth-snippet annotation
# (forward-auth headers to Authelia) gets honored. Without these the snippets
# are silently dropped.
echo "Enabling allow-snippet-annotations on ingress-nginx..."
kubectl patch cm -n ingress-nginx ingress-nginx-controller --type=merge \
  -p '{"data":{"allow-snippet-annotations":"true","annotations-risk-level":"Critical"}}'
kubectl rollout restart -n ingress-nginx deploy/ingress-nginx-controller

# Install ArgoCD
echo "Installing ArgoCD..."
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be up and running
echo "Waiting for ArgoCD to be up and running..."
kubectl wait --namespace argocd \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=argocd-server \
  --timeout=90s

# Create ArgoCD NodePort Service
echo "Creating ArgoCD NodePort Service..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: argocd-server-nodeport
  namespace: argocd
spec:
  type: NodePort
  ports:
    - port: 80
      targetPort: 8080
      nodePort: 32080
  selector:
    app.kubernetes.io/name: argocd-server
EOF

# Output ArgoCD username and password
echo "Retrieving ArgoCD initial admin password..."
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 --decode)
echo "ArgoCD Username: admin"
echo "ArgoCD Password: $ARGOCD_PASSWORD"

echo "k3s, ingress-nginx, and ArgoCD are up. ArgoCD will install MetalLB"
echo "and the rest of the cluster from the repo on first sync."


# Output instructions to get the token for joining nodes
get_ip_address() {
    hostname -I | awk '{print $1}'
}
PRIMARY_IP=$(get_ip_address)

echo "To join additional nodes to the cluster se the following command on the new node:"
echo "sudo ./bootstrap/node.sh $PRIMARY_IP $(sudo cat /var/lib/rancher/k3s/server/node-token)"
