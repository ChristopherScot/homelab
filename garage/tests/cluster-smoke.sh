#!/usr/bin/env bash
# End to end, against a real cluster: the committed manifests, rendered
# into a scratch namespace with small volumes, come up as a three-node
# Garage; bootstrap/garage-init.sh lays them out; an S3 client writes with
# the RW key and reads back with the RO key (and is refused a write); then
# one node is killed and the other two keep serving reads AND writes.
#
# A pod deletion stands in for a node outage. It is what the Garage layer
# sees in both cases - a peer vanishes - and it is reversible on a
# cluster other things are running on. What it does not exercise is the
# scheduler side (the pod waiting for its node to return), which the
# anti-affinity plus strict-local argument in statefulset.yaml covers.
#
# Needs a cluster, so in CI it SKIPs - and says so, because a check that
# cannot run must not look like one that did. Takes about 4 minutes;
# discovery alone is a 60s cycle.
#
# Run: garage/tests/cluster-smoke.sh
#   GARAGE_SMOKE_NS   scratch namespace (default garage-smoke)
#   GARAGE_SMOKE_KEEP set to keep the namespace afterwards for a look
#   GARAGE_SMOKE_IMPORT_FROM  namespace holding garage-s3-reference and
#                     garage-s3-seed to exercise the key IMPORT path
#                     (default: empty, keys are minted in the scratch ns)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src="$here/.."
NS="${GARAGE_SMOKE_NS:-garage-smoke}"
BUCKET=claude-reference

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*"; exit 0; }
step() { echo; echo "--- $*"; }

command -v kubectl >/dev/null 2>&1 || skip "kubectl not installed - nothing was deployed or tested"
kubectl cluster-info >/dev/null 2>&1 || skip "no reachable cluster - nothing was deployed or tested"
kubectl get sc longhorn >/dev/null 2>&1 || skip "no Longhorn in this cluster - nothing was deployed or tested"

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
# changed. The StorageClass and CRD are cluster-scoped and identical to
# what the real app owns, so they are applied as committed.
for f in configmap rbac statefulset; do
  sed -e "s/namespace: garage$/namespace: $NS/" \
      -e "s/namespace = \"garage\"/namespace = \"$NS\"/" \
      -e 's/storage: 30Gi/storage: 2Gi/' \
      -e 's/storage: 3Gi/storage: 1Gi/' \
      "$src/$f.yaml" > "$render/$f.yaml"
done
kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create secret generic garage-rpc \
  --from-literal=rpc-secret="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f "$src/storageclass.yaml" -f "$src/crd.yaml" \
  -f "$render/configmap.yaml" -f "$render/rbac.yaml" -f "$render/statefulset.yaml"

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
    echo "ok   $vol-garage-node-$i: replica and pod both on $pod_node"
  done
done

step "bootstrap: membership, layout, bucket, keys"
# Output goes through a file, not a pipe: the filter below drops the
# credential lines the script prints for freshly minted keys, and a
# pipe would make its exit status the filter's, not the script's.
init_out="$render/init.log"
if ! GARAGE_NS="$NS" GARAGE_CAPACITY=2Gi GARAGE_KEY_SOURCE_NS="${GARAGE_SMOKE_IMPORT_FROM:-}" \
    bash "$src/../bootstrap/garage-init.sh" >"$init_out" 2>&1; then
  grep -v -E '^(Key ID|Secret key):' "$init_out" | tail -30
  fail "garage-init.sh failed"
fi
grep -v -E '^(Key ID|Secret key|  |    |--- |===)' "$init_out" || true

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
              echo "ROUND TRIP OK"
          volumeMounts: [{name: shared, mountPath: /shared}]
      volumes: [{name: shared, emptyDir: {}}]
EOF
  kubectl -n "$NS" wait --for=condition=complete "job/$1" --timeout=180s >/dev/null \
    || { kubectl -n "$NS" logs "job/$1" --all-containers 2>&1 | tail -20; fail "job $1 did not complete"; }
  kubectl -n "$NS" logs "job/$1" --all-containers 2>/dev/null | grep -E '^(seed|worker|ROUND)'
}
s3_job smoke-s3 probe-full

step "one node down: the other two keep serving reads and writes"
victim=garage-node-1
victim_node="$(kubectl -n "$NS" get pod $victim -o jsonpath='{.spec.nodeName}')"
kubectl -n "$NS" delete pod $victim --wait=false >/dev/null
# The Service only routes to Ready pods, so the client never sees the
# dead one. The write below needs quorum (2 of 3), which is the claim.
s3_job smoke-s3-degraded probe-degraded
kubectl -n "$NS" exec garage-node-0 -- /garage status 2>/dev/null

step "the killed node comes back on the same k8s node and rejoins"
kubectl -n "$NS" wait --for=condition=Ready pod/$victim --timeout=180s >/dev/null
back_node="$(kubectl -n "$NS" get pod $victim -o jsonpath='{.spec.nodeName}')"
[ "$back_node" = "$victim_node" ] || fail "$victim came back on $back_node, its volumes are on $victim_node"
echo "ok   $victim Ready again on $back_node"

echo
echo "PASS: three-node garage serves S3 with one node down and the committed init script lays it out"
