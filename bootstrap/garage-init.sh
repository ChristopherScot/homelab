#!/usr/bin/env bash
# One-time Garage bootstrap: cluster layout, bucket, access keys.
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
# Two keys, deliberately. Workers get read-only: they all share one
# bucket, so an RW credential would let a buggy or compromised worker
# overwrite the books every other worker boots from. Object storage
# gives read isolation structurally; write isolation needs this.
KEY_RO="${GARAGE_KEY_RO:-claude-worker}"
KEY_RW="${GARAGE_KEY_RW:-claude-seed}"
ZONE="${GARAGE_ZONE:-home}"
# Gi, not G: this must track the data PVC in garage/statefulset.yaml,
# and 10G (decimal) against a 10Gi (binary) volume made garage advertise
# 9.3 GiB for a 10 GiB disk. Harmless at 74MB of use; misleading if the
# store is ever grown, because the two knobs live in different files.
CAPACITY="${GARAGE_CAPACITY:-10Gi}"

# Two wrappers, because this script asks garage two kinds of question
# and they want opposite error handling.
#
# g_try is for predicates - `if g_try bucket info X` - where a non-zero
# exit IS the answer ("it does not exist"), not a fault. It discards
# stderr, because garage logs an RPC handshake on every call and that
# noise buries this script's own output.
#
# g is for commands that must work. It discards the handshake too, but
# on failure re-runs with stderr attached so garage can say WHY, then
# exits. Without this a failing `bucket allow` died under set -e with no
# message at all: the caller saw a bare non-zero and the one line that
# would have explained it had gone to /dev/null. The first fix for that
# was a hand-rolled handler on one call site, which left its sibling two
# lines below still silent - hence doing it in the wrapper instead.
g_try() { kubectl exec -n "$NS" "$POD" -- /garage "$@" 2>/dev/null; }

g() {
  if kubectl exec -n "$NS" "$POD" -- /garage "$@" 2>/dev/null; then
    return 0
  fi
  echo "FATAL: garage $* failed; re-running to capture the error:" >&2
  kubectl exec -n "$NS" "$POD" -- /garage "$@" >&2 || true
  exit 1
}

echo "=== garage-init: ns=$NS pod=$POD ==="

# 1. Layout. `garage status` lists the node as NO ROLE ASSIGNED until
#    a layout version is applied; assigning twice is harmless but noisy,
#    so only do it when the role is genuinely missing.
if g_try status | grep -q 'NO ROLE ASSIGNED'; then
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
if g_try bucket info "$BUCKET" >/dev/null; then
  echo "bucket: $BUCKET exists"
else
  g bucket create "$BUCKET" >/dev/null
  echo "bucket: $BUCKET created"
fi

# 3. Keys, and their grants on the bucket. The grants are declarative,
#    so re-applying repairs one that drifted.
for k in "$KEY_RO" "$KEY_RW"; do
  if g_try key info "$k" >/dev/null; then
    echo "key: $k exists"
  else
    g key create "$k" >/dev/null
    echo "key: $k created"
  fi
done
# deny --write then allow --read, because allow only ADDS: running
# `allow --read` against a key that already had RW leaves it RW while
# the script cheerfully reports "has R". Asserting both directions
# makes the grant declarative, so this also downgrades a key that was
# created RW by an earlier version of this script.
g_try bucket deny --write "$BUCKET" --key "$KEY_RO" >/dev/null || true
g bucket allow --read "$BUCKET" --key "$KEY_RO" >/dev/null
echo "grant: $KEY_RO has R on $BUCKET"
g bucket allow --read --write "$BUCKET" --key "$KEY_RW" >/dev/null
echo "grant: $KEY_RW has RW on $BUCKET"

echo
echo "=== credentials - put these in Vault, then delete this output ==="
echo "--- $KEY_RO (read-only; this is the one workers get) ---"
g key info "$KEY_RO" --show-secret | grep -iE '^(Key ID|Secret key):'
echo "  vault kv put kv/garage/s3-reference \\"
echo "    access-key-id=<Key ID> secret-access-key=<Secret key>"
echo
echo "--- $KEY_RW (read-write; for seeding only, keep it out of the pods) ---"
g key info "$KEY_RW" --show-secret | grep -iE '^(Key ID|Secret key):'
