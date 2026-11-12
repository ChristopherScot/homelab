#!/usr/bin/env bash
# One-time Garage bootstrap: cluster layout, bucket, access key.
#
# Garage starts with NO ROLE ASSIGNED and stays that way until a layout
# is applied. Nothing in the manifests can do this - it is a cluster
# decision (which node, which zone, how much capacity), and Garage's own
# /health reports unhealthy until it is done, which is why the pod
# probes the S3 port rather than /health.
#
# Bucket, key and grant are check-then-create and safe to re-run; the
# grant is re-applied unconditionally, which repairs a drifted one.
#
# The layout step is weaker: assign and apply are two calls, so an
# apply that fails leaves a staged layout the next run will re-stage.
# It reads the staged version rather than guessing, and fails loudly if
# it cannot, but a cluster wedged mid-layout needs `garage layout show`
# and a human.
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
# Gi, not G: this must track the data PVC in garage/statefulset.yaml,
# and 10G (decimal) against a 10Gi (binary) volume made garage advertise
# 9.3 GiB for a 10 GiB disk. Harmless at 74MB of use; misleading if the
# store is ever grown, because the two knobs live in different files.
CAPACITY="${GARAGE_CAPACITY:-10Gi}"

# Garage logs an RPC handshake to stderr on every call, which
# buries this script's own output. The redirect is inside the
# function, so a caller cannot re-enable stderr by adding 2>&1 -
# use kubectl exec directly if you ever need it.
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
  # Read the staged version rather than assuming: garage prints
  # "Current cluster layout version: N", and applying the wrong number
  # is refused. The first draft globbed for "version N" without the
  # colon, so it never matched and silently fell back to 1 on every
  # run - correct only because a fresh cluster's first layout IS 1.
  ver="$(g layout show | sed -n 's/.*layout version: *\([0-9][0-9]*\).*/\1/p' | tail -1)"
  if [ -z "$ver" ]; then
    echo "FATAL: could not read the staged layout version from:" >&2
    g layout show >&2
    exit 1
  fi
  # apply takes the version being created, which is one past current.
  g layout apply --version "$((ver + 1))" >/dev/null
  echo "layout applied (version $((ver + 1)))"
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
