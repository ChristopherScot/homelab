#!/usr/bin/env bash
# Submit a runtime Job from the GitOps-managed CronJob. No scale/config patches.
set -euo pipefail
namespace="${CODEX_NAMESPACE:-codex-pods}"
follow=false
case "${1:-}" in
  '') ;;
  --follow) follow=true ;;
  --status)
    exec kubectl get jobs -n "$namespace" -l app=codex-runner
    ;;
  *) echo "usage: $0 [--follow|--status]" >&2; exit 64 ;;
esac

for dependency in kubectl jq; do
  command -v "$dependency" >/dev/null || { echo "Missing command: $dependency" >&2; exit 1; }
done

template="$(kubectl get cronjob codex-dependabot -n "$namespace" -o json)"
if ! jq -e '.spec.jobTemplate.spec.template.spec.containers[0].name == "codex"' \
  <<< "$template" >/dev/null; then
  echo 'The worker Job template is not deployed yet; wait for Argo CD to reconcile.' >&2
  exit 1
fi

active="$(kubectl get jobs -n "$namespace" -l app=codex-runner -o json | jq -r '
  .items[] | select(.metadata.deletionTimestamp == null)
  | select([.status.conditions[]? | select(.status == "True" and (.type == "Complete" or .type == "Failed"))] | length == 0)
  | .metadata.name')"
if [ -n "$active" ]; then
  printf 'A Codex run is already active:\n%s\n' "$active" >&2
  exit 75
fi

job="codex-manual-$(date -u +%Y%m%d%H%M%S)-$$"
kubectl create job "$job" --from=cronjob/codex-dependabot -n "$namespace"
printf '\nStarted %s. The pod exits when the task finishes; deadline: 6h30m.\n' "$job"
printf 'Logs: kubectl logs -f job/%s -n %s -c codex --pod-running-timeout=600s\n' "$job" "$namespace"
if "$follow"; then
  # logs --pod-running-timeout does not wait through ContainerCreating.
  # Accept a terminated container too: short jobs may finish before we observe it.
  startup_deadline=$((SECONDS + 600))
  started=false
  for _ in {1..120}; do
    if (( SECONDS >= startup_deadline )); then break; fi
    if kubectl get pods -n "$namespace" -l "job-name=$job" \
      --request-timeout=5s -o json | jq -e '
        any(.items[]?.status.containerStatuses[]?;
          .name == "codex" and (.state.running != null or .state.terminated != null))
      ' >/dev/null; then
      started=true
      break
    fi
    sleep 5
  done
  if ! "$started"; then
    printf 'Worker did not start within 10 minutes. Job %s continues independently.\n' "$job" >&2
    exit 1
  fi
  # Closing this log stream does not terminate the server-managed Job.
  kubectl logs -f "job/$job" -n "$namespace" -c codex --pod-running-timeout=600s
  # Kubelet log EOF can arrive before termination status reaches apiserver.
  # Missing status is not success; wait about a minute for the actual result.
  status_deadline=$((SECONDS + 60))
  for _ in {1..30}; do
    if (( SECONDS >= status_deadline )); then break; fi
    result="$(kubectl get pods -n "$namespace" -l "job-name=$job" \
      --request-timeout=5s \
      -o 'jsonpath={.items[0].status.containerStatuses[?(@.name=="codex")].state.terminated.exitCode}')"
    if [ -n "$result" ]; then exit "$result"; fi
    sleep 2
  done
  printf 'Could not confirm the worker exit status. Inspect Job %s.\n' "$job" >&2
  exit 1
fi
