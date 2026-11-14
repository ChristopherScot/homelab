#!/usr/bin/env bash
# `hold-run` — run something in a scale-to-zero pod and hold the pod open
# until it finishes.
#
#   hold-run desloppify [-- ENV=VAL ...]   # the nightly desloppify run
#   hold-run author <task> <repo>          # one claude-pods stage
#   hold-run test <task> <repo>
#   hold-run merge <task> <repo>
#
# The problem it solves: these pods scale to zero on a schedule that knows
# nothing about what they are doing. desloppify's KEDA ScaledObject runs a
# bare cron trigger (02:55-06:30 ET) and will scale the set to 0 at 06:30
# with an agent mid-run - which is exactly what happened on 2026-11-14,
# killing a manual run 17 minutes in. claude-session is better defended:
# session-sleep-cron checks `flock -n /tmp/nightly.lock` and leaves a busy
# pod awake. But nothing stops an ad-hoc run from racing either schedule.
#
# So: pin the replica count for the duration, run, unpin. For KEDA that is
# the `autoscaling.keda.sh/paused-replicas` annotation, which overrides the
# triggers entirely - verified against this cluster outside the cron
# window, where KEDA wanted 0 and scaled to 1 within 10s of the annotation
# landing, reporting Paused=True/ScaledObjectPaused.
#
# The unpin is in a trap, so Ctrl-C and most failures still release the
# hold. A SIGKILL will not run it, which is why `hold-run --release` exists
# as the manual undo.
set -euo pipefail

NS=${HOLD_RUN_NS:-claude-pods}

usage() {
  cat >&2 <<'USAGE'
hold-run — run something in a scale-to-zero pod, holding the pod open
until it finishes.

  hold-run desloppify [ENV=VAL ...]   the nightly desloppify run
  hold-run author <task> <repo>       one claude-pods stage
  hold-run test   <task> <repo>
  hold-run merge  <task> <repo>

  hold-run --release <kind>           drop a hold left behind by a
                                      SIGKILL or a lost connection

The hold is released on exit, including Ctrl-C. See the comment at the
top of this file for why it is needed.
USAGE
  exit "${1:-1}"
}

# Which StatefulSet and ScaledObject back each kind of run. The stage
# scripts are pinned to pod ordinals by the dispatcher's ROUTES; those
# names are duplicated here deliberately rather than parsed out of
# dispatch.mjs, because a wrong guess would exec into the wrong agent.
sts_for() {
  case "$1" in
    desloppify) echo "desloppify" ;;
    author|test|merge) echo "claude-session" ;;
    *) echo "" ;;
  esac
}

pod_for() {
  case "$1" in
    desloppify) echo "desloppify-0" ;;
    author) echo "claude-session-0" ;;
    merge) echo "claude-session-1" ;;
    test) echo "claude-session-2" ;;
    *) echo "" ;;
  esac
}

script_for() {
  case "$1" in
    desloppify) echo "/usr/local/bin/nightly-desloppify.sh" ;;
    # Dockerfile installs these as stage-*, not nightly-*.
    author) echo "/usr/local/bin/stage-author" ;;
    test) echo "/usr/local/bin/stage-test" ;;
    merge) echo "/usr/local/bin/stage-merge" ;;
    *) echo "" ;;
  esac
}

# Replicas needed for a given pod to exist: a StatefulSet creates ordinals
# 0..n-1, so holding claude-session-2 open means 3 replicas.
replicas_for() {
  case "$1" in
    desloppify|author) echo 1 ;;
    merge) echo 2 ;;
    test) echo 3 ;;
    *) echo 1 ;;
  esac
}

# Decided ONCE, before the trap is installed, and never re-queried.
# release() used to call have_scaledobject itself, so a transient
# `kubectl get` failure at cleanup time - an API blip, throttling, a
# control-plane restart - made it take the non-KEDA branch, print a
# reassuring message naming the wrong subsystem, and leave the pod
# pinned at 1 replica forever. The cleanup path is exactly where a
# failed call is least recoverable, so it does not make one.
KEDA_BACKED=unknown

have_scaledobject() {
  kubectl get scaledobject "$1" -n "$NS" >/dev/null 2>&1
}

hold() {
  local so=$1 want=$2
  if [ "$KEDA_BACKED" = yes ]; then
    kubectl annotate scaledobject "$so" -n "$NS" \
      "autoscaling.keda.sh/paused-replicas=$want" --overwrite >/dev/null
    echo "hold: KEDA pinned $so at $want replica(s)"
  else
    # No ScaledObject (claude-session is driven by the dispatcher and
    # session-sleep, not KEDA). Scaling directly is the hold; session-sleep
    # will not scale down a pod holding /tmp/nightly.lock, and the stage
    # script takes that lock itself.
    kubectl scale statefulset "$so" -n "$NS" --replicas="$want" >/dev/null
    echo "hold: scaled $so to $want replica(s)"
  fi
}

release() {
  local so=$1
  if [ "$KEDA_BACKED" = yes ]; then
    kubectl annotate scaledobject "$so" -n "$NS" \
      autoscaling.keda.sh/paused-replicas- >/dev/null 2>&1 || true
    echo "release: KEDA scheduling restored for $so"
  else
    # Deliberately does not scale down. session-sleep-cron runs every
    # 30 minutes and scales claude-session to 0 once its idle signals
    # clear, and it checks /tmp/nightly.lock first, so it will not pull
    # the floor out from under a live stage. Scaling down here would
    # race that check. Say so plainly: --release is documented as the
    # undo for a stuck hold, and on this path there is nothing stuck.
    echo "release: nothing to release for $so; session-sleep reclaims it within 30m"
  fi
}

wait_ready() {
  local pod=$1 budget=${2:-600} waited=0
  printf 'waiting for %s' "$pod"
  while [ "$waited" -lt "$budget" ]; do
    if [ "$(kubectl get pod "$pod" -n "$NS" \
         -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = true ]; then
      echo " ready (${waited}s)"
      return 0
    fi
    printf '.'
    sleep 5
    waited=$((waited + 5))
  done
  echo " TIMEOUT after ${budget}s"
  return 1
}

[ $# -ge 1 ] || usage 1

if [ "$1" = "--release" ]; then
  shift
  kind=${1:-}
  so=$(sts_for "$kind")
  [ -n "$so" ] || { echo "hold-run --release <desloppify|author|test|merge>" >&2; exit 1; }
  # --release skips the startup path, so resolve the one thing release
  # reads. Default to yes on a failed lookup: an unpin against a target
  # that has no ScaledObject is a harmless no-op, while skipping one
  # that does leaves the pod pinned - which is the whole failure this
  # subcommand exists to undo.
  if have_scaledobject "$so" || [ "$kind" = desloppify ]; then
    KEDA_BACKED=yes
  else
    KEDA_BACKED=no
  fi
  release "$so"
  exit 0
fi

kind=$1; shift
sts=$(sts_for "$kind")
pod=$(pod_for "$kind")
script=$(script_for "$kind")
[ -n "$sts" ] || usage 1

want=$(replicas_for "$kind")

# Refuse to start a second run beside a live one. The stage scripts take
# /tmp/nightly.lock themselves; desloppify has no lockfile, so its check is
# whether an agent process is already alive in the pod.
if kubectl get pod "$pod" -n "$NS" >/dev/null 2>&1; then
  busy=$(kubectl exec -n "$NS" "$pod" -- sh -c '
    flock -n /tmp/nightly.lock true 2>/dev/null || { echo busy; exit 0; }
    for p in /proc/[0-9]*; do
      [ -r "$p/comm" ] || continue
      read -r c < "$p/comm" 2>/dev/null
      # claude* not claude: the shipped binary is claude.exe, so comm
      # is `claude.exe` and an exact match never fires. Verified in the
      # pod by running the real binary and reading /proc/PID/comm.
      case "$c" in claude*) echo busy; exit 0 ;; esac
    done
    echo idle' 2>/dev/null || echo unknown)
  if [ "$busy" = busy ]; then
    echo "hold-run: $pod is already running something; refusing to start a second" >&2
    exit 1
  fi
fi

if have_scaledobject "$sts"; then KEDA_BACKED=yes; else KEDA_BACKED=no; fi

trap 'release "$sts"' EXIT INT TERM

hold "$sts" "$want"
wait_ready "$pod" 600 || { echo "hold-run: $pod never became ready" >&2; exit 1; }

# Split what follows into env assignments and positional arguments.
# `env` executes the first word that is not NAME=VALUE, so splicing them
# together ran `env mytask myrepo /usr/local/bin/stage-author` and died
# with "env: mytask: No such file or directory". The stage scripts take
# positionals (stage-author.sh reads ONLY_TASK="${1:-}"); desloppify
# takes none and is configured by environment.
envs=()
args=()
for a in "$@"; do
  case "$a" in
    [A-Za-z_]*=*) envs+=("$a") ;;
    *) args+=("$a") ;;
  esac
done

echo "running: ${envs[*]:+env ${envs[*]} }$script${args[*]:+ ${args[*]}}"
echo "---"
# Not detached: the point is to hold the pod open for exactly as long as
# the run takes, so this blocks and the trap releases when it returns.
#
# `|| rc=$?` rather than a bare call: under `set -e` a failing exec
# aborts the script before any following line, so the rc report was
# unreachable on exactly the failures worth reporting.
rc=0
kubectl exec -n "$NS" "$pod" -- \
  env "${envs[@]}" "$script" "${args[@]}" || rc=$?
echo "---"
echo "hold-run: $kind finished rc=$rc"
exit "$rc"
