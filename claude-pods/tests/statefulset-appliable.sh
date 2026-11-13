#!/usr/bin/env bash
# A StatefulSet's volumeClaimTemplates are immutable. The API does not
# ignore an edit to them - it rejects the WHOLE object:
#
#   Forbidden: updates to statefulset spec for fields other than
#   'replicas', 'ordinals', 'template', 'updateStrategy',
#   'persistentVolumeClaimRetentionPolicy' and 'minReadySeconds'
#
# This app auto-syncs (prune + selfHeal), so such an edit does not
# document an intention - it parks the Application at SyncFailed. And
# argocd-image-updater pins the pod image on that same Application, so
# the next image roll stops landing with no obvious cause: a change
# merged weeks later appears not to ship, far from this file.
#
# That is how a 5Gi -> 15Gi edit nearly shipped: the PVCs had already
# been resized by hand, so the template edit bought nothing and would
# have cost the delivery path.
#
# This check asks the API whether the committed manifest applies, which
# is the only thing that can say "immutable field changed". That needs
# a cluster, so in CI it SKIPs - a check that cannot run must not look
# like one that did.
#
# WHAT ACTUALLY GUARANTEES THIS, as of 2026-11-13: nothing but running
# this test with cluster access. The obvious backstop - Argo alerting
# on SyncFailed - does not exist here: argocd-notifications-cm in the
# argocd namespace has zero keys, so although the controller is running
# it has no triggers configured. Until that changes, a forbidden edit
# is caught either by someone running this locally or by someone
# noticing the Application stuck at SyncFailed. If you wire up
# SyncFailed alerting later, that becomes the real guarantee and this
# test becomes a pre-push convenience - say so here when you do.
#
# Run: claude-pods/tests/statefulset-appliable.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
sts="$here/../statefulset.yaml"
ns=claude-pods
name=claude-session

fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 0; }

[ -f "$sts" ] || fail "$sts not found"

# A skip is a real gap in coverage, not a pass. Say which protection is
# missing, so a wall of green in CI does not read as "this was checked".
command -v kubectl >/dev/null 2>&1 \
  || skip "kubectl not installed - the committed manifest was NOT checked against the API"
kubectl cluster-info >/dev/null 2>&1 \
  || skip "no reachable cluster - the committed manifest was NOT checked against the API"
kubectl get sts "$name" -n "$ns" >/dev/null 2>&1 \
  || skip "StatefulSet $name not deployed in $ns - nothing to compare against"

# The authoritative check: ask the API whether this manifest applies.
# --dry-run=server runs the same admission the real sync would.
out=$(kubectl apply -f "$sts" --dry-run=server 2>&1) || {
  echo "$out" | grep -q 'Forbidden' && fail \
"the committed StatefulSet cannot be applied; Argo will sit at SyncFailed
    and image rolls on this Application will stop landing.

    $out

    An immutable field (almost always a volumeClaimTemplates size) differs
    from the live object. Either revert that field to the live value, or
    recreate the StatefulSet deliberately:
      kubectl delete sts $name -n $ns --cascade=orphan   # at 0 replicas
    checking persistentVolumeClaimRetentionPolicy first."
  fail "kubectl apply --dry-run=server failed: $out"
}

echo "PASS: claude-pods/statefulset.yaml applies cleanly against the live cluster ($out)"
