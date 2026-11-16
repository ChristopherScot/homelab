#!/usr/bin/env bash
# The invariants that make three Garage nodes survive one k8s node going
# away, checked against the committed manifests. Each is something a
# reasonable edit could undo without any error at apply time: a replica
# count, a storage class, a probe path, a name that two files must agree
# on. Argo would apply the result happily and the loss would show up as
# an outage months later.
#
# Needs yq (mikefarah v4). Run: garage/tests/manifests.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
dir="$here/.."
fails=0

fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
expect() { # <description> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else fail "$1: got '$2', want '$3'"; fi
}
# yq over a multi-document file, selecting one kind (and optionally name).
q() { # <file> <kind> <expr> [name]
  local f="$dir/$1" kind="$2" expr="$3" name="${4:-}"
  if [ -n "$name" ]; then
    yq -r "select(.kind == \"$kind\" and .metadata.name == \"$name\") | $expr" "$f"
  else
    yq -r "select(.kind == \"$kind\") | $expr" "$f"
  fi
}

# Locally a missing yq is a skip that says so. In CI it is a failure: this
# is the only one of the garage tests CI can run, and a green run that
# checked nothing is worse than a red one.
command -v yq >/dev/null 2>&1 || {
  echo "SKIP: yq not installed - manifests were NOT checked"
  [ -z "${CI:-}" ] || { echo "FAIL: CI must have yq"; exit 1; }
  exit 0
}

sts=statefulset.yaml
cm=configmap.yaml
toml="$(q $cm ConfigMap '.data["garage.toml"]')"
tomlval() { # <key> -> value, quotes stripped
  printf '%s\n' "$toml" | sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}.*/\1/p" | head -1
}

# --- redundancy ---------------------------------------------------------
expect "three garage nodes" "$(q $sts StatefulSet .spec.replicas)" 3
expect "garage replicates three times" "$(tomlval replication_factor)" 3
expect "consistent mode (no stale reads below quorum)" "$(tomlval consistency_mode)" consistent
expect "pods start in parallel (Ready needs quorum, so ordered would deadlock)" \
  "$(q $sts StatefulSet .spec.podManagementPolicy)" Parallel
expect "one pod per k8s node, as a hard rule" \
  "$(q $sts StatefulSet '.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].topologyKey')" \
  kubernetes.io/hostname
expect "anti-affinity selects the garage pods themselves" \
  "$(q $sts StatefulSet '.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].labelSelector.matchLabels.app')" \
  "$(q $sts StatefulSet '.spec.template.metadata.labels.app')"
expect "a drain may take at most one node" "$(q $sts PodDisruptionBudget .spec.maxUnavailable)" 1
expect "PDB covers the garage pods" \
  "$(q $sts PodDisruptionBudget .spec.selector.matchLabels.app)" \
  "$(q $sts StatefulSet '.spec.template.metadata.labels.app')"
expect "fsync metadata (nodes share one mains supply)" "$(tomlval metadata_fsync)" true
expect "fsync data" "$(tomlval data_fsync)" true

# --- where the redundancy lives: Garage, not Longhorn ---------------------
sc="$(q storageclass.yaml StorageClass .metadata.name)"
expect "storage class: one Longhorn replica" "$(q storageclass.yaml StorageClass '.parameters.numberOfReplicas')" 1
expect "storage class: replica pinned to the pod's node" "$(q storageclass.yaml StorageClass '.parameters.dataLocality')" strict-local
expect "storage class: bind after scheduling (strict-local needs the node first)" \
  "$(q storageclass.yaml StorageClass .volumeBindingMode)" WaitForFirstConsumer
for vol in meta data; do
  expect "$vol volume uses $sc" \
    "$(q $sts StatefulSet ".spec.volumeClaimTemplates[] | select(.metadata.name == \"$vol\") | .spec.storageClassName")" "$sc"
done

# --- the init script names what the manifests name -----------------------
init="$dir/../bootstrap/garage-init.sh"
expect "init script default StatefulSet name" \
  "$(sed -n 's/^STS="\${GARAGE_STS:-\(.*\)}"$/\1/p' "$init")" "$(q $sts StatefulSet .metadata.name)"
expect "an exported empty GARAGE_KEY_*_SECRET disables import (cluster-smoke.sh relies on it)" \
  "$(grep -c '_SECRET-claude-pods/' "$init")" 2

# --- readiness is garage's own health, and the S3 Service follows it -----
expect "readiness probes /health" \
  "$(q $sts StatefulSet '.spec.template.spec.containers[0].readinessProbe.httpGet.path')" /health
expect "readiness probes the admin port" \
  "$(q $sts StatefulSet '.spec.template.spec.containers[0].readinessProbe.httpGet.port')" admin
expect "liveness does NOT use /health (quorum loss is not fixed by a restart)" \
  "$(q $sts StatefulSet '.spec.template.spec.containers[0].livenessProbe.httpGet // "none"')" none
expect "S3 Service selects the garage pods" \
  "$(q $cm Service .spec.selector.app garage)" "$(q $sts StatefulSet '.spec.template.metadata.labels.app')"
expect "the S3 Service is still called garage" "$(q $cm Service .metadata.name garage)" garage
expect "secrets.yaml projects the endpoint URL into both S3 Secrets" \
  "$(grep -c AWS_ENDPOINT_URL "$dir/secrets.yaml")" 2
expect "no endpoint URL in secrets.yaml names anything else" \
  "$(grep AWS_ENDPOINT_URL "$dir/secrets.yaml" | grep -vc 'http://garage.garage.svc.cluster.local:3900')" 0
expect "headless Service is the StatefulSet's serviceName" \
  "$(q $cm Service .metadata.name garage-node)" "$(q $sts StatefulSet .spec.serviceName)"
expect "headless Service is headless" "$(q $cm Service .spec.clusterIP garage-node)" None

# --- peer discovery: config, RBAC and CRD name the same things -----------
expect "discovery namespace is the garage namespace" "$(tomlval namespace)" "$(q $sts StatefulSet .metadata.namespace)"
expect "discovery service_name is the headless Service" "$(tomlval service_name)" "$(q $cm Service .metadata.name garage-node)"
expect "garage does not create the CRD itself" "$(tomlval skip_crd)" true
expect "the CRD is committed instead" "$(q crd.yaml CustomResourceDefinition .metadata.name)" garagenodes.deuxfleurs.fr
expect "Role grants the GarageNode resource" "$(q rbac.yaml Role '.rules[0].resources[0]')" "$(q crd.yaml CustomResourceDefinition .spec.names.plural)"
expect "Role grants the CRD's group" "$(q rbac.yaml Role '.rules[0].apiGroups[0]')" "$(q crd.yaml CustomResourceDefinition .spec.group)"
expect "pods run as the bound ServiceAccount" \
  "$(q $sts StatefulSet .spec.template.spec.serviceAccountName)" "$(q rbac.yaml RoleBinding '.subjects[0].name')"
expect "no static rpc_public_addr (three pods share one file)" "$(tomlval rpc_public_addr)" ""

if [ "$fails" -gt 0 ]; then echo "FAIL: $fails invariant(s) broken"; exit 1; fi
echo "PASS: garage manifests keep their redundancy invariants"
