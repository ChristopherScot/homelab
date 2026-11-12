#!/usr/bin/env bash
# One-time Garage bootstrap: cluster layout, bucket, access key.
#
# Garage starts with NO ROLE ASSIGNED and stays that way until a layout
# is applied. Nothing in the manifests can do this - it is a cluster
# decision (which node, which zone, how much capacity), and Garage's own
# /health reports unhealthy until it is done, which is why the pod
# probes the S3 port rather than /health.
#
# Idempotent: every step checks first, so re-running after a redeploy
# is safe and reports what already existed.
#
# The secret key is printed ONCE at the end, by `garage key info
# --show-secret`. Put it in Vault, not in this repo:
#   vault kv put kv/garage/s3-reference \
#     access-key-id=... secret-access-key=...
set -euo pipefail

NS="${GARAGE_NS:-garage}"
POD="${GARAGE_POD:-garage-0}"
BUCKET="${GARAGE_BUCKET:-claude-reference}"
KEY="${GARAGE_KEY:-claude-worker}"
ZONE="${GARAGE_ZONE:-home}"
CAPACITY="${GARAGE_CAPACITY:-10G}"

# Garage logs an RPC handshake to stderr on every call, which
# buries this script's own output. Callers that need stderr
# (the credential dump) re-enable it explicitly.
g() { kubectl exec -n "$NS" "$POD" -- /garage "$@" 2>/dev/null; }

echo "=== garage-init: ns=$NS pod=$POD ==="

# 1. Layout. `garage status` lists the node as NO ROLE ASSIGNED until
#    a layout version is applied; assigning twice is harmless but noisy,
#    so only do it when the role is genuinely missing.
if g status 2>/dev/null | grep -q 'NO ROLE ASSIGNED'; then
  node="$(g node id -q 2>/dev/null | tail -1 | cut -d@ -f1)"
  [ -n "$node" ] || { echo "FATAL: could not read node id" >&2; exit 1; }
  echo "assigning layout to ${node:0:16}... zone=$ZONE capacity=$CAPACITY"
  g layout assign -z "$ZONE" -c "$CAPACITY" "$node" >/dev/null
  # Version 1 on a fresh cluster; a later re-run would need the next
  # number, which `layout show` prints.
  ver="$(g layout show 2>/dev/null | grep -oE 'version [0-9]+' | tail -1 | awk '{print $2}')"
  g layout apply --version "${ver:-1}" >/dev/null
  echo "layout applied"
else
  echo "layout: already assigned"
fi

# 2. Bucket.
if g bucket info "$BUCKET" >/dev/null 2>&1; then
  echo "bucket: $BUCKET exists"
else
  g bucket create "$BUCKET" >/dev/null
  echo "bucket: $BUCKET created"
fi

# 3. Key, and its grant on the bucket.
if g key info "$KEY" >/dev/null 2>&1; then
  echo "key: $KEY exists"
else
  g key create "$KEY" >/dev/null
  echo "key: $KEY created"
fi
g bucket allow --read --write "$BUCKET" --key "$KEY" >/dev/null
echo "grant: $KEY has RW on $BUCKET"

echo
echo "=== credentials - put these in Vault, then delete this output ==="
g key info "$KEY" --show-secret | grep -iE '^(Key ID|Secret key):'
echo
echo "  vault kv put kv/garage/s3-reference \\"
echo "    access-key-id=<Key ID> secret-access-key=<Secret key>"
