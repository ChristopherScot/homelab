#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Install k3s with Traefik and Service Load Balancer disabled, and use etcd as the datastore
echo "Installing k3s with Traefik and Service Load Balancer disabled, using etcd as the datastore..."
curl -sfL https://get.k3s.io | sh -s - server --disable traefik --disable servicelb --cluster-init

# Wait for k3s to be up and running
echo "Waiting for k3s to be up and running..."
sleep 30

# Set KUBECONFIG environment variable
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Set permissions for kubeconfig file
echo "Setting permissions for kubeconfig file..."
sudo chmod 644 /etc/rancher/k3s/k3s.yaml

# Install MetalLB
echo "Installing MetalLB..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/main/config/manifests/metallb-native.yaml


# Wait for MetalLB to be up and running
echo "Waiting for MetalLB to be up and running..."
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s


# Create MetalLB IP Address Pool
echo "Creating MetalLB Address Pool..."
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: primary-pool-ipv4
  namespace: metallb-system
spec:
  addresses:
  - 192.168.50.225-192.168.50.250
EOF

echo "Creating MetalLB L2Advertisement..."
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - primary-pool-ipv4
EOF

# Install NGINX Ingress Controller
echo "Installing NGINX Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml

# Wait for NGINX Ingress Controller to be up and running
echo "Waiting for NGINX Ingress Controller to be up and running..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s

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

echo "k3s cluster with NGINX Ingress, MetalLB, and ArgoCD is up and running!"


# Output instructions to get the token for joining nodes
get_ip_address() {
    hostname -I | awk '{print $1}'
}
PRIMARY_IP=$(get_ip_address)

echo "To join additional nodes to the cluster se the following command on the new node:"
echo "sudo ./bootstrap/node.sh $PRIMARY_IP $(sudo cat /var/lib/rancher/k3s/server/node-token)"
