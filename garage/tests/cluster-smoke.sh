#!/usr/bin/env bash
# End to end, against a real cluster: the committed manifests, rendered
# into a scratch namespace with small volumes, come up as a three-node
# Garage; bootstrap/garage-init.sh lays them out; an S3 client writes with
# the RW key and reads back with the RO key (and is refused a write); then
# each Garage peer is isolated in turn and the remaining pair keeps
# serving reads AND writes.
#
# Temporarily orphan the scratch StatefulSet's pods, remove one peer,
# and restore the controller after checking the surviving pair. This
# keeps the selected peer absent throughout the requests without stopping
# physical hosts or testing Kubernetes control-plane/DNS failover.
#
# Needs a cluster, so in CI it SKIPs - and says so, because a check that
# cannot run must not look like one that did. Takes about 4 minutes;
# discovery alone is a 60s cycle.
#
# Run: GARAGE_SMOKE_RUN=1 bash garage/tests/cluster-smoke.sh
#   GARAGE_SMOKE_NS   scratch namespace (default garage-smoke)
#   GARAGE_SMOKE_KEEP set to keep the namespace afterwards for a look
#   GARAGE_SMOKE_IMPORT  set to let garage-init.sh import the real keys
#                     from claude-pods (its default) and so exercise the
#                     import path; otherwise keys are minted in the
#                     scratch namespace and never leave it
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src="$here/.."
NS="${GARAGE_SMOKE_NS:-garage-smoke}"
BUCKET=claude-reference

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*"; exit 0; }
step() { echo; echo "--- $*"; }

[ "${GARAGE_SMOKE_RUN:-}" = 1 ] || skip "set GARAGE_SMOKE_RUN=1 to deploy scratch resources"

command -v kubectl >/dev/null 2>&1 || skip "kubectl not installed - nothing was deployed or tested"
kubectl cluster-info >/dev/null 2>&1 || skip "no reachable cluster - nothing was deployed or tested"
kubectl get sc longhorn >/dev/null 2>&1 || skip "no Longhorn in this cluster - nothing was deployed or tested"

# Never take ownership of an existing namespace or delete its contents.
existing="$(kubectl get ns "$NS" --ignore-not-found -o name)"
[ -z "$existing" ] || fail "namespace $NS already exists; choose a fresh GARAGE_SMOKE_NS"
render=$(mktemp -d)
cleanup() {
  rm -rf "$render"
  if [ -n "${GARAGE_SMOKE_KEEP:-}" ]; then
    echo "keeping namespace $NS (GARAGE_SMOKE_KEEP set)"
  else
    kubectl delete ns "$NS" --wait=false >/dev/null 2>&1 || true
    echo "namespace $NS deleted (volumes go with it; the class is reclaim Delete)"
  fi
}
trap cleanup EXIT

step "render into $NS with small volumes"
# The same files Argo applies, with only the namespace and the sizes
# changed. The sizes are matched by shape, not value, so a resize in
# statefulset.yaml cannot leave this applying full-size volumes to a
# scratch namespace.
for f in configmap rbac statefulset; do
  sed -E -e "s/namespace: garage$/namespace: $NS/" \
      -e "s/namespace = \"garage\"/namespace = \"$NS\"/" \
      -e 's/storage: [0-9]+Gi$/storage: 1Gi/' \
      "$src/$f.yaml" > "$render/$f.yaml"
done
grep -q 'storage: 1Gi' "$render/statefulset.yaml" || fail "could not shrink the volume sizes in statefulset.yaml"
# The StorageClass and CRD are cluster-scoped: there is one of each, the
# real app owns it, and Argo self-heals it. A test must not write to
# them. Create them only when absent (a cluster that has never run
# garage); otherwise require the committed file to match what is live,
# so a branch that changes either is told to let Argo reconcile first
# rather than silently testing against the old one.
for f in storageclass crd; do
  if kubectl get -f "$src/$f.yaml" >/dev/null 2>&1; then
    # diff prints nothing when clean and the diff when not; exit 1 is
    # "differs", anything higher is kubectl itself failing.
    if kubectl diff -f "$src/$f.yaml"; then
      echo "$f.yaml: live object matches the committed file"
    else
      rc=$?
      [ "$rc" -eq 1 ] && fail "$f.yaml differs from the live object (above); it is Argo's to change, not this test's"
      fail "kubectl diff -f $f.yaml failed (exit $rc)"
    fi
  else
    kubectl apply -f "$src/$f.yaml"
  fi
done
kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create secret generic garage-rpc \
  --from-literal=rpc-secret="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f "$render/configmap.yaml" -f "$render/rbac.yaml" -f "$render/statefulset.yaml"

step "pods land on three different nodes"
kubectl -n "$NS" wait --for=condition=PodScheduled pod -l app=garage-node --timeout=120s >/dev/null
nodes="$(kubectl -n "$NS" get pod -l app=garage-node -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')"
[ "$nodes" = 3 ] || fail "garage pods on $nodes distinct nodes, want 3"
kubectl -n "$NS" get pod -l app=garage-node -o wide
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Running pod -l app=garage-node --timeout=180s >/dev/null

step "each volume's single replica is on its pod's node"
for i in 0 1 2; do
  pod_node="$(kubectl -n "$NS" get pod garage-node-$i -o jsonpath='{.spec.nodeName}')"
  for vol in meta data; do
    pv="$(kubectl -n "$NS" get pvc "$vol-garage-node-$i" -o jsonpath='{.spec.volumeName}')"
    rep_node="$(kubectl -n longhorn-system get replicas.longhorn.io -o json \
      | jq -r --arg pv "$pv" '.items[] | select(.spec.volumeName == $pv) | .spec.nodeID')"
    [ "$rep_node" = "$pod_node" ] || fail "$vol-garage-node-$i replica on '$rep_node', pod on '$pod_node'"
    affinity="$(kubectl get pv "$pv" -o json | jq -r '
      .spec.nodeAffinity.required.nodeSelectorTerms[].matchExpressions[] |
      select(.key == "kubernetes.io/hostname" and .operator == "In") | .values[]')"
    [ "$affinity" = "$pod_node" ] || fail "$pv affinity '$affinity' does not pin $pod_node"
    echo "ok   $vol-garage-node-$i: replica and PV affinity both on $pod_node"
  done
done

step "bootstrap: membership, layout, bucket, keys"
# Output goes through a file, not a pipe: the filter below drops the
# credential lines the script prints for freshly minted keys, and a
# pipe would make its exit status the filter's, not the script's.
init_out="$render/init.log"
if [ -z "${GARAGE_SMOKE_IMPORT:-}" ]; then
  export GARAGE_KEY_RO_SECRET="" GARAGE_KEY_RW_SECRET=""
fi
# On success, an allowlist of the step lines: if the script's credential
# block is ever reworded, unknown output is dropped rather than echoed.
# On failure the diagnosis is the lines AFTER each FATAL headline (garage's
# stderr, kubectl's error, the layout the script refused), so the whole
# log is shown minus the two line shapes that carry a secret, before the
# cleanup trap deletes it.
if ! GARAGE_NS="$NS" bash "$src/../bootstrap/garage-init.sh" >"$init_out" 2>&1; then
  grep -v -E '^(Key ID|Secret key):' "$init_out" | tail -40
  fail "garage-init.sh failed"
fi
grep -E '^(membership|layout|bucket|key|grant)' "$init_out" || true

step "all three Ready through /health"
kubectl -n "$NS" wait --for=condition=Ready pod -l app=garage-node --timeout=120s >/dev/null
kubectl -n "$NS" exec garage-node-0 -- /garage status 2>/dev/null

step "S3 round trip: write with RW key, read with RO key, RO write refused"
# Credentials come from garage itself, into Secrets in this namespace
# only; nothing is printed.
mk_secret() { # <secret name> <key name>
  local info id secret
  info="$(kubectl -n "$NS" exec garage-node-0 -- /garage key info "$2" --show-secret 2>/dev/null)"
  id="$(printf '%s\n' "$info" | sed -n 's/^Key ID: *//p')"
  secret="$(printf '%s\n' "$info" | sed -n 's/^Secret key: *//p')"
  [ -n "$id" ] && [ -n "$secret" ] || fail "could not read key $2"
  kubectl -n "$NS" create secret generic "$1" \
    --from-literal=AWS_ACCESS_KEY_ID="$id" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$secret" \
    --from-literal=AWS_DEFAULT_REGION=garage \
    --from-literal=AWS_ENDPOINT_URL="http://garage.$NS.svc.cluster.local:3900" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}
mk_secret s3-rw claude-seed
mk_secret s3-ro claude-worker

# One Job, two containers in sequence via init: the seeder writes, the
# worker reads back and tries to write. Same shape as
# claude-pods/worker/poc-worker-job.yaml, which is the real consumer.
s3_job() { # <job name> <object key>
  kubectl -n "$NS" delete job "$1" --ignore-not-found >/dev/null
  kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata: {name: $1}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      initContainers:
        - name: seed
          image: amazon/aws-cli:2.17.0
          envFrom: [{secretRef: {name: s3-rw}}]
          command: [sh, -c]
          args:
            - |
              set -eu
              head -c 3000000 /dev/urandom > /shared/payload
              aws s3 cp /shared/payload s3://$BUCKET/$2 --only-show-errors
              sha256sum /shared/payload | cut -d ' ' -f 1 > /shared/checksum
              aws s3 cp /shared/checksum s3://$BUCKET/$2.sha256 --only-show-errors
              echo "seed: wrote $2"
          volumeMounts: [{name: shared, mountPath: /shared}]
      containers:
        - name: worker
          image: amazon/aws-cli:2.17.0
          envFrom: [{secretRef: {name: s3-ro}}]
          command: [sh, -c]
          args:
            - |
              set -eu
              aws s3 cp s3://$BUCKET/$2 /shared/readback --only-show-errors
              cmp /shared/payload /shared/readback && echo "worker: read back byte-identical"
              if aws s3 cp /shared/payload s3://$BUCKET/should-fail --only-show-errors 2>/dev/null; then
                echo "worker: RO key was allowed to write"; exit 1
              fi
              echo "worker: RO write refused"
              aws s3 cp s3://$BUCKET/probe-full /shared/original --only-show-errors
              aws s3 cp s3://$BUCKET/probe-full.sha256 /shared/expected --only-show-errors
              sha256sum /shared/original | cut -d ' ' -f 1 > /shared/actual
              cmp /shared/expected /shared/actual
              echo "worker: original object checksum verified"
              echo "ROUND TRIP OK"
          volumeMounts: [{name: shared, mountPath: /shared}]
      volumes: [{name: shared, emptyDir: {}}]
EOF
  kubectl -n "$NS" wait --for=condition=complete "job/$1" --timeout=180s >/dev/null \
    || { kubectl -n "$NS" logs "job/$1" --all-containers 2>&1 | tail -20; fail "job $1 did not complete"; }
  kubectl -n "$NS" logs "job/$1" --all-containers 2>/dev/null | grep -E '^(seed|worker|ROUND)'
}
s3_job smoke-s3 probe-full

step "each peer unavailable in turn: all surviving pairs serve reads and writes"
for ordinal in 0 1 2; do
  victim="garage-node-$ordinal"
  # Orphaning preserves the live pods and PVCs but stops immediate
  # replacement of the selected ordinal. The namespace belongs to this
  # test alone; reapplying the manifest adopts the other two pods.
  kubectl -n "$NS" delete sts garage-node --cascade=orphan --wait=true >/dev/null
  kubectl -n "$NS" delete pod "$victim" --wait=true >/dev/null
  for _ in $(seq 1 30); do
    ready="$(kubectl -n "$NS" get endpoints garage -o json | jq -r '[.subsets[]?.addresses[]?.targetRef.name] | sort | join(" ")')"
    expected="$(printf '%s\n' garage-node-0 garage-node-1 garage-node-2 | grep -v "^$victim$" | sort | paste -sd ' ' -)"
    [ "$ready" = "$expected" ] && break
    sleep 2
  done
  [ "$ready" = "$expected" ] || fail "expected endpoints '$expected', got '$ready'"
  s3_job "smoke-s3-down-$ordinal" "probe-down-$ordinal"
  absent="$(kubectl -n "$NS" get pod "$victim" --ignore-not-found -o name)"
  [ -z "$absent" ] || fail "$victim was recreated during the outage test"
  echo "ok   $victim absent: surviving pair serves existing data and new writes"
  kubectl apply -f "$render/statefulset.yaml" >/dev/null
  kubectl -n "$NS" rollout status sts/garage-node --timeout=180s >/dev/null
done

step "all pods restart on their original hosts"
before="$(kubectl -n "$NS" get pod -l app=garage-node -o json | jq -S '[.items[] | {name:.metadata.name,node:.spec.nodeName}] | sort_by(.name)')"
kubectl -n "$NS" delete pod -l app=garage-node --wait=true >/dev/null
kubectl -n "$NS" rollout status sts/garage-node --timeout=240s >/dev/null
after="$(kubectl -n "$NS" get pod -l app=garage-node -o json | jq -S '[.items[] | {name:.metadata.name,node:.spec.nodeName}] | sort_by(.name)')"
[ "$before" = "$after" ] || fail "pod-to-host mapping changed after full restart"
s3_job smoke-s3-restarted probe-restarted

echo
echo "PASS: bootstrap, each single-peer outage, full restart, and RO/RW S3 access"
