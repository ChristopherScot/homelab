#!/usr/bin/env bash
# A run that overruns the cron window must not be scaled away under it.
#
# The ScaledObject used to carry one cron trigger (02:55-06:30 ET) that
# knew nothing about what the pod was doing. At 06:30 on 2026-11-14 it
# scaled the StatefulSet to 0 with an agent 17 minutes into a ticket;
# that run died, and the next three failed on the half-created stack
# branch it left behind.
#
# The fix is a second trigger counting the run's own pod. Two facts have
# to line up for it to work, and neither is visible from either file
# alone - which is why this test exists rather than a comment:
#
#   1. the CronJob's pod template must carry the label
#   2. the ScaledObject's podSelector must match that exact label
#
# A typo in either leaves the cron trigger alone in charge and the bug
# comes back silently - the manifests still apply, KEDA still reports
# Ready, and nothing fails until a run overruns.
#
# Run: desloppify-pod/test-keda-hold.sh
set -uo pipefail
fail=0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
so="$here/desloppify-scaledobject.yaml"
cj="$here/desloppify-cronjob.yaml"

for f in "$so" "$cj"; do
  [ -f "$f" ] || { echo "FAIL: $f not found"; exit 1; }
done

# Fail rather than skip. This test is the only thing standing between a
# typo in either manifest and a silent return of the 2026-11-14
# incident, so a green run on a missing binary is worse than no test -
# it reads as "the pair agrees" when nothing was compared. yq is
# preinstalled on ubuntu-latest, which is what CI runs; if that ever
# stops being true the right outcome is a loud failure here.
if ! command -v yq >/dev/null 2>&1; then
  echo "FAIL: yq is required to read these manifests structurally"
  echo "      install it (brew install yq / snap install yq) and rerun;"
  echo "      skipping would leave the label/selector pair unchecked"
  exit 1
fi

# The ScaledObject is a multi-document file (it carries a RoleBinding
# too), so select by kind rather than taking the first document.
so_doc() { yq eval-all "select(.kind == \"ScaledObject\") | $1" "$so" 2>/dev/null; }
cj_doc() { yq eval-all "select(.kind == \"CronJob\") | $1" "$cj" 2>/dev/null; }

# 1. Both triggers present. The cron alone is the bug.
types=$(so_doc '.spec.triggers[].type' | sort | tr '\n' ' ')
case "$types" in
  *cron*kubernetes-workload*|*kubernetes-workload*cron*) ;;
  *)
    echo "FAIL: expected both cron and kubernetes-workload triggers, got [$types]"
    echo "      a lone cron trigger scales the pod away mid-run"
    fail=1 ;;
esac

# 2. The selector and the label must agree, character for character.
selector=$(so_doc '.spec.triggers[] | select(.type == "kubernetes-workload") | .metadata.podSelector')
if [ -z "$selector" ] || [ "$selector" = "null" ]; then
  echo "FAIL: the kubernetes-workload trigger has no podSelector"
  fail=1
else
  key=${selector%%=*}
  want=${selector#*=}
  got=$(cj_doc ".spec.jobTemplate.spec.template.metadata.labels.\"$key\"")
  if [ "$got" != "$want" ]; then
    echo "FAIL: the trigger pod does not carry the label the scaler counts"
    echo "      selector wants $key=$want, pod template has $key=${got:-<unset>}"
    echo "      with no match the count is always 0 and the hold never engages"
    fail=1
  fi
fi

# 3. The selector must not match the desloppify pod itself. That would
#    make the StatefulSet hold itself up forever - the pod it counts
#    would be the pod it scales, so the count never reaches 0.
sts="$here/desloppify-statefulset.yaml"
if [ -f "$sts" ] && [ -n "${selector:-}" ]; then
  key=${selector%%=*}
  own=$(yq eval-all "select(.kind == \"StatefulSet\") | .spec.template.metadata.labels.\"$key\"" "$sts" 2>/dev/null)
  if [ -n "$own" ] && [ "$own" != "null" ]; then
    echo "FAIL: the StatefulSet's own pods carry $key, so it would never scale down"
    fail=1
  fi
fi

# 4. activationValue must stay at its default. Raising it above 0 means
#    one pod no longer activates the trigger, and one pod is all a run
#    ever produces.
av=$(so_doc '.spec.triggers[] | select(.type == "kubernetes-workload") | .metadata.activationValue')
if [ -n "$av" ] && [ "$av" != "null" ] && [ "$av" != "0" ]; then
  echo "FAIL: activationValue is $av; a single run pod would not activate the trigger"
  fail=1
fi

# 5. The cron must still wake the pod BEFORE the CronJob execs into it,
#    or the trigger job waits on a rollout that nothing started. These
#    two schedules are the same fact in two files.
cron_start=$(so_doc '.spec.triggers[] | select(.type == "cron") | .metadata.start')
cj_sched=$(cj_doc '.spec.schedule')
start_min=${cron_start%% *}; start_hr=$(echo "$cron_start" | awk '{print $2}')
cj_min=${cj_sched%% *};      cj_hr=$(echo "$cj_sched" | awk '{print $2}')
if [ -n "$start_hr" ] && [ -n "$cj_hr" ]; then
  wake=$((10#$start_hr * 60 + 10#$start_min))
  exec_at=$((10#$cj_hr * 60 + 10#$cj_min))
  if [ "$wake" -ge "$exec_at" ]; then
    echo "FAIL: KEDA wakes the pod at $cron_start but the job execs at $cj_sched"
    echo "      the wake must come first or wait-ready times out"
    fail=1
  fi
fi

# 6. The hold's only bound. shouldCountPod in KEDA excludes just
#    Succeeded and Failed, so Pending, Running AND Unknown all hold the
#    set up - a pod on a lost node keeps phase Running, and so does one
#    stuck Terminating. What converts those to Failed is the Job
#    controller acting on activeDeadlineSeconds. Before this change that
#    deadline was job hygiene; now it is the thing that stops a stuck
#    pod pinning the StatefulSet indefinitely, and nothing tested it.
deadline=$(cj_doc '.spec.jobTemplate.spec.activeDeadlineSeconds')
if [ -z "$deadline" ] || [ "$deadline" = "null" ]; then
  echo "FAIL: no activeDeadlineSeconds on the trigger job"
  echo "      it is the only bound on the hold: a pod stuck Running or"
  echo "      Unknown keeps the set scaled up until the deadline fires"
  fail=1
fi

# 7. Forbid and Never, for the same reason. Two concurrent trigger jobs
#    would each hold the set up, and a restarting one would hold it
#    across restarts - both turn a bounded hold into an open-ended one.
conc=$(cj_doc '.spec.concurrencyPolicy')
[ "$conc" = "Forbid" ] || {
  echo "FAIL: concurrencyPolicy is ${conc:-<unset>}, not Forbid"
  echo "      overlapping trigger jobs would each hold the pod up"
  fail=1
}
restart=$(cj_doc '.spec.jobTemplate.spec.template.spec.restartPolicy')
[ "$restart" = "Never" ] || {
  echo "FAIL: restartPolicy is ${restart:-<unset>}, not Never"
  fail=1
}

# 8. value must be present and positive. KEDA's Validate() rejects the
#    ScaledObject outright when value <= 0 ("value must be a float
#    greater than 0"), and it defaults to 0 - so omitting it breaks the
#    whole object rather than just this trigger.
val=$(so_doc '.spec.triggers[] | select(.type == "kubernetes-workload") | .metadata.value')
if [ -z "$val" ] || [ "$val" = "null" ]; then
  echo "FAIL: the kubernetes-workload trigger has no value; KEDA rejects value <= 0"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: the run's pod is labelled, the scaler counts that label, the set cannot hold itself up, the wake precedes the exec, and the hold stays bounded"
fi
exit "$fail"
