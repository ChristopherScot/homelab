#!/usr/bin/env bash
# One-time Garage bootstrap: cluster layout, bucket, access keys.
#
# Garage nodes start with NO ROLE ASSIGNED and stay that way until a
# layout is applied. Nothing in the manifests can do this - it is a
# cluster decision (which zone, how much capacity), and Garage's own
# /health reports unhealthy until it is done, which is why a fresh
# StatefulSet sits at 0/3 Ready until this has run. kubectl exec does not
# wait on readiness, so there is no lockout.
#
# Every step is check-then-act and safe to re-run. The layout step
# assigns only nodes that have no role yet, so re-running after a node
# was re-admitted (garage/README.md) assigns just that one; the bucket
# and keys are created only if missing; the grants are re-applied
# unconditionally, which repairs a drifted one.
#
# Keys: the two S3 keys already live in Vault (kv/garage/s3-reference and
# kv/garage/s3-seed), projected into Secrets in the claude-pods namespace.
# A key Garage does not know yet is IMPORTED from there rather than
# minted, so rebuilding the cluster does not invalidate what every
# consumer already holds. Only when no Secret exists is a key created, and
# its secret printed ONCE at the end for seeding Vault. The import passes
# the secret as a command argument, so for a moment it is visible to `ps`
# on the machine running this script; run it from your own machine, not a
# shared one.
set -euo pipefail

NS="${GARAGE_NS:-garage}"
STS="${GARAGE_STS:-garage-node}"
# Any member works for admin commands; they proxy to the cluster.
POD="${GARAGE_POD:-$STS-0}"
BUCKET="${GARAGE_BUCKET:-claude-reference}"
# Two keys, deliberately. Workers get read-only: they all share one
# bucket, so an RW credential would let a buggy or compromised worker
# overwrite the books every other worker boots from. Object storage
# gives read isolation structurally; write isolation needs this.
KEY_RO="${GARAGE_KEY_RO:-claude-worker}"
KEY_RW="${GARAGE_KEY_RW:-claude-seed}"
# Where the Vault-projected S3 Secrets live, and their names. Empty
# KEY_SOURCE_NS disables import (fresh keys are minted and printed).
KEY_SOURCE_NS="${GARAGE_KEY_SOURCE_NS-claude-pods}"
SECRET_RO="${GARAGE_SECRET_RO:-garage-s3-reference}"
SECRET_RW="${GARAGE_SECRET_RW:-garage-s3-seed}"
# Per node. Must track the data PVC in garage/statefulset.yaml; garage
# accepts Gi here (it parsed 4Gi as 4.0 GiB) so the two files can say
# the same thing. Garage uses it to weight the layout, and with three
# equal nodes at replication_factor 3 it is also the usable total.
CAPACITY="${GARAGE_CAPACITY:-30Gi}"

# Two wrappers, because this script asks garage two kinds of question
# and they want opposite error handling.
#
# g_try is for predicates - `if g_try bucket info X` - where a non-zero
# exit IS the answer ("it does not exist"), not a fault. It discards
# stderr, because garage logs an RPC handshake on every call and that
# noise buries this script's own output.
#
# g is for commands that must work. It captures stderr to a temp file on
# the FIRST call and prints it only on failure, so the handshake stays
# out of the way while a real error still gets through. Without this a
# failing `bucket allow` died under set -e with no message at all.
#
# Capturing rather than re-running on failure: `garage key create` mints
# a NEW key every call - name is not a unique index - so re-running it
# after a timeout that had already succeeded server-side would leave two
# keys sharing one name. It also returns rather than exits: `exit` inside
# a function only leaves the subshell when g is in a pipeline or $(...).
g_try() { kubectl exec -n "$NS" "$POD" -- /garage "$@" 2>/dev/null; }

g() {
  local err rc=0
  err="$(mktemp)"
  # `|| rc=$?` and not a bare call: under set -e a failing command
  # inside a function aborts the script immediately, so the handler
  # below would never run and the error would be discarded. It is also
  # what lets the plain rm below suffice: an earlier version used a
  # RETURN trap for it, but a RETURN trap is global once set and fires
  # when the CALLER returns too, where $err is out of scope and set -u
  # aborts the script - which is exactly what happened the first time g
  # was called from inside another function.
  kubectl exec -n "$NS" "$POD" -- /garage "$@" 2>"$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FATAL: garage $* failed (exit $rc):" >&2
    cat "$err" >&2
  fi
  rm -f "$err"
  return "$rc"
}

# The HEALTHY NODES table of `garage status`, one line per node:
#   <id-prefix> <hostname> <assigned|unassigned>
# Stops at the next ==== header so the STAGED ROLE CHANGES table that
# follows (same id-first shape) is not mistaken for nodes. A node whose
# role is staged but not applied shows "pending..." and is treated as
# assigned, so a re-run after a failed apply does not stage it twice.
#
# A node that discovery has found but that has not finished its
# handshake lists with hostname "?" - it is in the table before it is a
# member. Leave it out: counting it made the membership wait below pass
# 30 seconds after a fresh start, and the layout step then asked
# Kubernetes for a pod called "?".
healthy_nodes() {
  g_try status | awk '
    /^==== HEALTHY NODES/ { in_table = 1; next }
    /^====/               { in_table = 0 }
    in_table && /^[0-9a-f]{16} / && $2 != "?" {
      print $1, $2, (/NO ROLE ASSIGNED/ ? "unassigned" : "assigned")
    }'
}

echo "=== garage-init: ns=$NS sts=$STS via $POD ==="

# 1. Membership. Nodes find each other through Kubernetes discovery once
#    a minute, so a fresh cluster is not whole for up to a minute after
#    the pods start. A layout at replication_factor 3 cannot be applied
#    with fewer than 3 nodes, so wait for all of them rather than fail
#    on a race the operator did not cause.
want="$(kubectl get sts -n "$NS" "$STS" -o jsonpath='{.spec.replicas}')"
[ -n "$want" ] || { echo "FATAL: cannot read $STS replicas in $NS" >&2; exit 1; }
for _ in $(seq 1 18); do
  have="$(healthy_nodes | wc -l | tr -d ' ')"
  [ "$have" -ge "$want" ] && break
  echo "membership: $have of $want nodes visible, waiting for discovery..."
  sleep 10
done
[ "$have" -ge "$want" ] || {
  echo "FATAL: only $have of $want nodes joined; check 'garage status' and the GarageNode objects" >&2
  exit 1
}

# 2. Layout. One zone per k8s node, named after it, so a layout listing
#    reads as the machines it describes and Garage keeps the three copies
#    of every object on three different machines (it treats zones as
#    failure domains). The pod's node is asked for rather than assumed
#    from the ordinal: anti-affinity fixes the mapping, but nothing says
#    which ordinal landed where.
staged=0
while read -r id host role; do
  [ "$role" = "unassigned" ] || continue
  zone="$(kubectl get pod -n "$NS" "$host" -o jsonpath='{.spec.nodeName}')"
  [ -n "$zone" ] || { echo "FATAL: cannot find the k8s node running $host" >&2; exit 1; }
  echo "layout: assigning $id ($host) zone=$zone capacity=$CAPACITY"
  g layout assign -z "$zone" -c "$CAPACITY" "$id" >/dev/null
  staged=$((staged + 1))
done < <(healthy_nodes)

if [ "$staged" -gt 0 ]; then
  # `layout show` ends with the exact command to run, version included.
  # Parse that rather than computing current+1: when staged changes are
  # unusable (too few nodes for the replication factor) there is no such
  # line, and the explanation above it is the error to show.
  show="$(g layout show)"
  ver="$(printf '%s\n' "$show" | sed -n 's/.*garage layout apply --version \([0-9][0-9]*\).*/\1/p' | tail -1)"
  if [ -z "$ver" ]; then
    echo "FATAL: staged layout cannot be applied:" >&2
    printf '%s\n' "$show" >&2
    exit 1
  fi
  g layout apply --version "$ver" >/dev/null
  echo "layout: applied version $ver ($staged node(s) assigned)"
else
  echo "layout: all $have nodes already assigned"
fi

# 3. Bucket.
if g_try bucket info "$BUCKET" >/dev/null; then
  echo "bucket: $BUCKET exists"
else
  g bucket create "$BUCKET" >/dev/null
  echo "bucket: $BUCKET created"
fi

# 4. Keys. Imported from the existing Secret when there is one, so the
#    cluster learns the credential consumers already hold; created only
#    when there is nothing to import. `key info <name>` resolves a name,
#    so an existing key is found whichever way it was made.
secret_field() { # <secret> <key>
  kubectl get secret -n "$KEY_SOURCE_NS" "$1" -o "jsonpath={.data.$2}" 2>/dev/null | base64 -d
}

created=()
ensure_key() { # <key name> <secret name>
  local name="$1" secret="$2" have_id want_id want_secret
  if g_try key info "$name" >/dev/null; then
    have_id="$(g_try key info "$name" | sed -n 's/^Key ID: *//p')"
    if [ -n "$KEY_SOURCE_NS" ]; then
      want_id="$(secret_field "$secret" AWS_ACCESS_KEY_ID || true)"
      if [ -n "$want_id" ] && [ "$want_id" != "$have_id" ]; then
        echo "WARNING: key $name is $have_id in garage but $KEY_SOURCE_NS/$secret holds $want_id;" >&2
        echo "         consumers of that Secret cannot authenticate. Reconcile Vault or the key." >&2
      fi
    fi
    echo "key: $name exists ($have_id)"
    return
  fi
  want_id=""
  if [ -n "$KEY_SOURCE_NS" ]; then
    want_id="$(secret_field "$secret" AWS_ACCESS_KEY_ID || true)"
    want_secret="$(secret_field "$secret" AWS_SECRET_ACCESS_KEY || true)"
  fi
  if [ -n "$want_id" ] && [ -n "$want_secret" ]; then
    g key import --yes -n "$name" "$want_id" "$want_secret" >/dev/null
    echo "key: $name imported from $KEY_SOURCE_NS/$secret ($want_id)"
  else
    g key create "$name" >/dev/null
    if [ -n "$KEY_SOURCE_NS" ]; then
      echo "key: $name created (no $KEY_SOURCE_NS/$secret to import from)"
    else
      echo "key: $name created (import disabled)"
    fi
    created+=("$name")
  fi
}
ensure_key "$KEY_RO" "$SECRET_RO"
ensure_key "$KEY_RW" "$SECRET_RW"

# 5. Grants. deny --write then allow --read, because allow only ADDS:
#    running `allow --read` against a key that already had RW leaves it
#    RW while the script cheerfully reports "has R". Asserting both
#    directions makes the grant declarative.
g_try bucket deny --write "$BUCKET" --key "$KEY_RO" >/dev/null || true
g bucket allow --read "$BUCKET" --key "$KEY_RO" >/dev/null
echo "grant: $KEY_RO has R on $BUCKET"
g bucket allow --read --write "$BUCKET" --key "$KEY_RW" >/dev/null
echo "grant: $KEY_RW has RW on $BUCKET"

# 6. Only keys this run minted need seeding; imported ones are already
#    where they belong.
if [ "${#created[@]}" -gt 0 ]; then
  echo
  echo "=== credentials - put these in Vault, then delete this output ==="
  for k in "${created[@]}"; do
    case "$k" in
      "$KEY_RO") path=kv/garage/s3-reference ;;
      *)         path=kv/garage/s3-seed ;;
    esac
    echo "--- $k ---"
    g key info "$k" --show-secret | grep -iE '^(Key ID|Secret key):'
    echo "  vault kv put $path \\"
    echo "    access-key-id=<Key ID> secret-access-key=<Secret key>"
  done
fi
