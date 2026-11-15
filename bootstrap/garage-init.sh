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
# assigns only nodes that have no role yet, and refuses to run while a
# role belongs to a node that is gone - that is the re-admit case, which
# needs `layout assign --replace` by hand (garage/README.md), and after
# it this script has nothing left to assign. The bucket and keys are
# created only if missing; the grants are re-applied unconditionally,
# which repairs a drifted one.
#
# Keys: the two S3 keys already live in Vault, projected by External
# Secrets into Secrets in the claude-pods namespace. A key Garage does
# not know yet is IMPORTED from there rather than minted, so rebuilding
# the cluster does not invalidate what every consumer already holds. A
# key is minted only when there is nothing to import: no Secret and no
# ExternalSecret waiting to project one, or import switched off by
# exporting an empty GARAGE_KEY_*_SECRET - which is what a first-ever
# cluster needs, since Argo creates the ExternalSecrets before Vault
# holds anything. A minted key's secret is printed ONCE at the end for
# seeding Vault.
#
# `garage key import` only takes the secret as an argument, so for the
# length of that one call it is in the argv of kubectl here, in the exec
# request to the API server (and so in API audit logs, if enabled), and
# in the process table of the node running the garage pod. Nothing lands
# in a log this script writes. Run it from your own machine.
#
# Needs kubectl and jq.
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
# Each key names the namespace/Secret it is imported from; empty means
# never import, always mint. `-` and not `:-` on the two *_SECRET
# defaults, deliberately: an exported empty value must win, which is how
# garage/tests/cluster-smoke.sh keeps the real keys out of its scratch
# namespace.
KEY_RO="${GARAGE_KEY_RO:-claude-worker}"
KEY_RO_SECRET="${GARAGE_KEY_RO_SECRET-claude-pods/garage-s3-reference}"
KEY_RW="${GARAGE_KEY_RW:-claude-seed}"
KEY_RW_SECRET="${GARAGE_KEY_RW_SECRET-claude-pods/garage-s3-seed}"
# No capacity knob: each node's capacity is the size of its data PVC,
# read when the node is assigned. Growing a running cluster is a layout
# change by hand (garage/README.md), not a re-run of this.

# Capture diagnostics without repeating a mutating command. Import failures
# omit output as well as arguments: either may contain the supplied secret.
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
    echo "FATAL: garage ${1:-command} ${2:-} failed (exit $rc)" >&2
    if [ "${1:-}" != key ] || [ "${2:-}" != import ]; then
      cat "$err" >&2
    fi
  fi
  rm -f "$err"
  return "$rc"
}

# Cluster members, one per line: <id> <hostname> <assigned|unassigned>,
# from the admin API's JSON. Two things it makes structural: a node that
# discovery has found but not finished a handshake with has no hostname
# yet and is not a member; and a role that is staged but not yet applied
# counts as assigned, so a re-run after a failed apply does not stage it
# twice.
healthy_nodes() {
  local status layout
  status="$(g json-api GetClusterStatus)" || return 1
  layout="$(g json-api GetClusterLayout)" || return 1
  jq -rn --argjson s "$status" --argjson l "$layout" '
    ([$l.roles[].id] + [$l.stagedRoleChanges[].id]) as $have
    | $s.nodes[]
    | select(.isUp and .hostname != null)
    | .id as $id
    | "\($id) \(.hostname) \(if ($have | index($id)) then "assigned" else "unassigned" end)"'
}

# Applied or staged roles whose node is not up, one id per line. Once every pod the
# StatefulSet wants is a member, such a role is a node that was lost and
# replaced (its identity lives on its meta volume) or a StatefulSet
# scaled below its layout; either way the layout still maps a share of
# every partition to it. Unlike healthy_nodes this is a one-shot gate,
# not a poll, so a failed admin call is reported (g) and returned as a
# failure rather than read as "no dead roles".
dead_roles() {
  local status layout
  status="$(g json-api GetClusterStatus)" || return 2
  layout="$(g json-api GetClusterLayout)" || return 2
  jq -rn --argjson s "$status" --argjson l "$layout" '
    [$s.nodes[] | select(.isUp) | .id] as $up
    | ([$l.roles[].id] + [$l.stagedRoleChanges[] | select(.remove != true) | .id] | unique)[]
    | select(. as $id | $up | index($id) | not)'
}

echo "=== garage-init: ns=$NS sts=$STS via $POD ==="

# 1. Membership. Nodes find each other through Kubernetes discovery once
#    a minute, so a fresh cluster is not whole for up to a minute after
#    the pods start. A layout at replication_factor 3 cannot be applied
#    with fewer than 3 nodes, so wait for all of them rather than fail
#    on a race the operator did not cause.
want="$(kubectl get sts -n "$NS" "$STS" -o jsonpath='{.spec.replicas}')"
[ -n "$want" ] || { echo "FATAL: cannot read $STS replicas in $NS" >&2; exit 1; }
#    healthy_nodes prints nothing while garage is unreachable (a pod still
#    attaching its volumes); the `|| true` is for jq choking on a response
#    it does not expect, which should be another empty poll rather than a
#    silent exit under set -e.
for _ in $(seq 1 18); do
  have="$(healthy_nodes 2>/dev/null | wc -l | tr -d ' ' || true)"
  [ "${have:-0}" -ge "$want" ] && break
  echo "membership: ${have:-0} of $want nodes visible, waiting for discovery..."
  sleep 10
done
[ "${have:-0}" -ge "$want" ] || {
  echo "FATAL: only ${have:-0} of $want nodes joined; garage status says:" >&2
  g status >&2 || true
  echo "Also check the GarageNode objects: kubectl get garagenodes -n $NS" >&2
  exit 1
}

# 2. Layout. One zone per k8s node, named after it, so a layout listing
#    reads as the machines it describes and Garage keeps the three copies
#    of every object on three different machines (it treats zones as
#    failure domains). The pod's node and its PVC's size are asked for
#    rather than assumed: anti-affinity fixes the node mapping but
#    nothing says which ordinal landed where, and the PVC is the one
#    place the capacity is declared (garage accepts the same Gi form).
#
#    A role held by a node that is gone is refused, not worked around:
#    assigning its replacement next to it would apply a layout in which
#    a share of every partition belongs to a node that will never return,
#    and garage would run degraded while this script printed "applied".
#    The fix is `layout assign --replace`, which only a human can decide.
dead="$(dead_roles)" || exit 1
if [ -n "$dead" ]; then
  echo "FATAL: the layout still holds a role for a node that is not up:" >&2
  printf '%s\n' "$dead" >&2
  echo "If $STS is simply scaled below its layout (kubectl get sts -n $NS $STS), scale it back." >&2
  echo "Otherwise a node whose meta volume was lost has come back as a new id: replace the" >&2
  echo "old one by hand (garage/README.md, 'Re-admitting a node'), then re-run this." >&2
  exit 1
fi
members="$(healthy_nodes)" || exit 1
while read -r id host role; do
  [ "$role" = "unassigned" ] || continue
  zone="$(kubectl get pod -n "$NS" "$host" -o jsonpath='{.spec.nodeName}')"
  [ -n "$zone" ] || { echo "FATAL: cannot find the k8s node running $host" >&2; exit 1; }
  cap="$(kubectl get pvc -n "$NS" "data-$host" -o jsonpath='{.status.capacity.storage}')"
  [ -n "$cap" ] || { echo "FATAL: cannot read the size of PVC data-$host" >&2; exit 1; }
  echo "layout: assigning ${id:0:16} ($host) zone=$zone capacity=$cap"
  g layout assign -z "$zone" -c "$cap" "$id" >/dev/null
done <<< "$members"

# Include assignments left staged by an interrupted previous invocation.
layout="$(g json-api GetClusterLayout)"
staged="$(printf '%s' "$layout" | jq -er '.stagedRoleChanges | length | tostring')"
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
buckets="$(g json-api ListBuckets)"
bucket_exists="$(printf '%s' "$buckets" | jq -r --arg name "$BUCKET" 'any(.[]; (.globalAliases | index($name)) != null)')"
if [ "$bucket_exists" = true ]; then
  echo "bucket: $BUCKET exists"
else
  g bucket create "$BUCKET" >/dev/null
  echo "bucket: $BUCKET created"
fi

# 4. Keys. Imported from the named Secret when there is one, so the
#    cluster learns the credential consumers already hold; created only
#    when there is nothing to import. `key info <name>` resolves a name,
#    so an existing key is found whichever way it was made.
#
#    The Secret is read once, as JSON, with stderr kept. "No such Secret"
#    is the one answer that may mean mint; a denied read or an API that
#    is down must not be mistaken for it, because minting on a fault
#    hands consumers a key they do not hold - the outcome the import
#    exists to prevent. Returns 1 when absent, 2 on a fault (already
#    reported), since `exit` here would only leave the $().
secret_json() { # <namespace/secret>
  local out
  out="$(kubectl get secret -n "${1%%/*}" "${1#*/}" --ignore-not-found -o json)" || {
    echo "FATAL: cannot read Secret $1" >&2
    return 2
  }
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}
secret_field() { # <json> <field>
  printf '%s' "$1" | jq -r ".data.$2 // empty" | base64 -d
}

created=()
drift=0
ensure_key() { # <key name> <namespace/secret, or empty>
  local name="$1" from="$2" have_id have_secret want_id="" want_secret="" json keys external rc=0
  keys="$(g json-api ListKeys)" || return 1
  have_id="$(printf '%s' "$keys" | jq -er --arg name "$name" '
    [.[] | select(.name == $name)] |
    if length > 1 then error("multiple keys share the requested name")
    elif length == 1 then .[0].id else "" end')" || return 1
  if [ -n "$from" ]; then
    json="$(secret_json "$from")" || rc=$?
    case "$rc" in
      0)
        want_id="$(secret_field "$json" AWS_ACCESS_KEY_ID)"
        want_secret="$(secret_field "$json" AWS_SECRET_ACCESS_KEY)"
        [ -n "$want_id" ] && [ -n "$want_secret" ] || {
          echo "FATAL: $from has no AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY to import" >&2; exit 1; }
        ;;
      1)
        # Absent with no ExternalSecret either means nothing has ever
        # claimed this key: mint. Absent while the ExternalSecret exists
        # is ambiguous - Vault has never held the key (a first-ever
        # cluster; Argo creates the ExternalSecret before anyone seeds
        # Vault), or Vault, its policy or the SecretStore is broken. The
        # script cannot tell them apart and the second must not get a
        # minted key papering over it, so the operator decides: fix the
        # projection, or switch import off to mint and seed Vault.
        external="$(kubectl get externalsecret -n "${from%%/*}" "${from#*/}" --ignore-not-found -o name)" || return 1
        if [ -n "$external" ]; then
          echo "FATAL: ExternalSecret $from exists but has produced no Secret." >&2
          echo "       If Vault should already hold this key, fix the projection:" >&2
          echo "         kubectl describe externalsecret -n ${from%%/*} ${from#*/}" >&2
          echo "       If Vault has never held it (first-ever cluster), mint and then seed it:" >&2
          echo "         GARAGE_KEY_RO_SECRET= GARAGE_KEY_RW_SECRET= $0" >&2
          exit 1
        fi
        ;;
      *) exit 1 ;;
    esac
  fi
  if [ -n "$have_id" ]; then
    if [ -n "$want_id" ]; then
      # Reported here, fatal at the end: the grants below are still worth
      # applying, but a run that leaves consumers unable to authenticate
      # must not exit 0 - this is the failure the import step exists to
      # prevent, and a WARNING line in a scrolled terminal is not a report.
      # Both halves are compared; Vault is seeded by hand, so a right ID
      # with a wrong secret is as plausible as a wrong ID.
      have_secret="$(g key info "$have_id" --show-secret | sed -n 's/^Secret key: *//p')" || return 1
      [ -n "$have_secret" ] || { echo "FATAL: could not read existing key secret" >&2; return 1; }
      if [ "$want_id" != "$have_id" ]; then
        echo "ERROR: key $name is $have_id in garage but $from holds $want_id;" >&2
        echo "       consumers of that Secret cannot authenticate. Reconcile Vault or the key." >&2
        drift=1
      elif [ "$want_secret" != "$have_secret" ]; then
        echo "ERROR: key $name ($have_id) has a different secret in garage than $from holds;" >&2
        echo "       consumers of that Secret cannot authenticate. Reconcile Vault or the key." >&2
        drift=1
      fi
    fi
    echo "key: $name exists ($have_id)"
  elif [ -n "$want_id" ]; then
    g key import --yes -n "$name" "$want_id" "$want_secret" >/dev/null
    echo "key: $name imported from $from ($want_id)"
  else
    g key create "$name" >/dev/null
    if [ -n "$from" ]; then
      echo "key: $name created (no $from to import from)"
    else
      echo "key: $name created (import disabled)"
    fi
    created+=("$name:$from")
  fi
}
ensure_key "$KEY_RO" "$KEY_RO_SECRET"
ensure_key "$KEY_RW" "$KEY_RW_SECRET"

# 5. Grants. deny --write then allow --read, because allow only ADDS:
#    running `allow --read` against a key that already had RW leaves it
#    RW while the script cheerfully reports "has R". Asserting both
#    directions makes the grant declarative.
g bucket deny --write "$BUCKET" --key "$KEY_RO" >/dev/null
g bucket allow --read "$BUCKET" --key "$KEY_RO" >/dev/null
echo "grant: $KEY_RO has R on $BUCKET"
g bucket allow --read --write "$BUCKET" --key "$KEY_RW" >/dev/null
echo "grant: $KEY_RW has RW on $BUCKET"

# 6. Minted keys must be seeded into Vault before consumers can use them.
if [ "${#created[@]}" -gt 0 ]; then
  echo
  echo "=== credentials - put these in Vault, then delete this output ==="
  for entry in "${created[@]}"; do
    k="${entry%%:*}"
    echo "--- $k ---"
    g key info "$k" --show-secret | grep -iE '^(Key ID|Secret key):'
    echo "  Seed the Vault path referenced by this consumer's ExternalSecret."
  done
fi

if [ "$drift" -ne 0 ]; then
  echo "FATAL: a key in garage does not match the Secret its consumers hold (see ERROR above)" >&2
  exit 1
fi
