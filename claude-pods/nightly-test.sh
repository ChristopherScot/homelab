#!/usr/bin/env bash
# Pod 2's job: try hard to break the PRs pod 0 opened, and file issues for
# what actually breaks.
#
# Runs at 02:00, between authoring (00:00) and the merge verdict (04:00),
# so anything it finds is on the PR before pod 1 decides. A bug found at
# 02:00 is a NO-MERGE at 04:00; the same bug found after the merge is a
# revert.
#
# Deliberately separate from pod 1. Pod 1 asks "is this good code?" and
# pod 2 asks "where does it break?" — different questions, and bundling
# them means the second gets answered carelessly once the first looks fine.
set -uo pipefail

PER_PR_TIMEOUT="${NIGHTLY_PR_TIMEOUT:-2700}"
OWNER="${NIGHTLY_OWNER:-ChristopherScot}"
STATE_DIR="${NIGHTLY_STATE_DIR:-/workspace/.nightly}"
QUIET_MINUTES="${NIGHTLY_QUIET_MINUTES:-30}"
LOG="$STATE_DIR/test-$(date +%Y%m%d).log"

mkdir -p "$STATE_DIR"
# Tee to the PVC log AND to pid 1's stdout, so the run shows up in Loki.
#
# These scripts run under `kubectl exec`, which is a separate process from
# the container's pid 1 (`sleep infinity`, which stops writing after the
# entrypoint finishes). Their output goes to the exec stream and never
# reaches container stdout, so Alloy had nothing to collect and a whole
# 2am run left no trace in Grafana — queryable only as a file inside a
# PVC. Writing to /proc/1/fd/1 puts it where the log collector looks.
#
# Falls back to the file alone if that fd is not writable, rather than
# losing the log entirely.
if [ -w /proc/1/fd/1 ]; then
  exec > >(tee -a "$LOG" > /proc/1/fd/1) 2>&1
else
  exec > >(tee -a "$LOG") 2>&1
fi
echo "=== nightly-test $(date -Is) ==="

# Preferred model with a fallback: a capped model fails every PR rather
# than degrading, so probe once and switch if it is unavailable.
MODEL="${NIGHTLY_MODEL:-claude-fable-5-1}"
MODEL_FALLBACK="${NIGHTLY_MODEL_FALLBACK:-opus}"
pick_model() {
  local probe
  probe=$(cd /workspace && timeout 120 claude -p --model "$MODEL" "Reply with exactly: OK" 2>&1 | tail -2)
  if printf '%s' "$probe" | grep -qiE "spend limit|rate limit|not support this model|unavailable"; then
    echo "model $MODEL unavailable ($(printf '%s' "$probe" | head -1)); falling back to $MODEL_FALLBACK" >&2
    MODEL="$MODEL_FALLBACK"
  fi
  echo "using model: $MODEL" >&2
}

PROMPT_DIR="${NIGHTLY_PROMPT_DIR:-/usr/local/share/claude-pods/prompts}"
# acceptEdits allows file edits but NOT shell commands, so without an
# explicit allow-list every gh / go test / kubectl call stops for an
# approval nobody is there to give. Scoped list, not bypassPermissions.
NIGHTLY_SETTINGS="${NIGHTLY_SETTINGS:-/usr/local/share/claude-pods/prompts/nightly-settings.json}"
render_prompt() {
  local f="$1"
  if [ ! -r "$f" ]; then
    echo "FATAL: prompt not readable: $f" >&2
    exit 1
  fi
  # node, not python3: python3 is not installed in this image. It appeared
  # to work when probed through an interactive shell, but `kubectl exec`
  # gets a plain PATH and every ticket died on "python3: command not
  # found" before a prompt was ever rendered.
  node -e '
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8");
process.stdout.write(src.replace(/\$(\w+)/g, (m, k) =>
  Object.prototype.hasOwnProperty.call(process.env, k) ? process.env[k] : m));
' "$f"
}

GH_TOKEN="$(cat /run/secrets/git/token 2>/dev/null)"
export GH_TOKEN
if [ -z "$GH_TOKEN" ]; then echo "FATAL: no GitHub token"; exit 1; fi

# Refuse to start on a credential that cannot work.
#
# ~/.claude/.credentials.json is periodically found with accessToken and
# refreshToken as EMPTY STRINGS and expiresAt=0. Valid JSON, right shape,
# no tokens. Claude Code reads it as expired-in-1970 and cannot renew,
# because the refresh token it would renew with was blanked too.
#
# Cause unknown. It has hit different pods on different nights, and never
# all three at once — so a healthy peer is normally available to copy
# from. Without this check the run burns its whole window failing every
# ticket on "OAuth session expired".
cred_ok() {
  kubectl exec -n "${NIGHTLY_NS:-claude-pods}" "$1" -- node -e '
    const f = process.env.HOME + "/.claude/.credentials.json";
    let d; try { d = require(f).claudeAiOauth; } catch (e) { process.exit(1); }
    if (!d || !d.accessToken || !d.refreshToken) process.exit(1);
    if (!(d.expiresAt > Date.now())) process.exit(1);
  ' >/dev/null 2>&1
}

preflight_credential() {
  local me="${HOSTNAME:-unknown}"
  if cred_ok "$me"; then
    echo "credential: ok"
    return 0
  fi
  echo "credential: INVALID on $me — looking for a healthy peer" >&2
  local peer
  for peer in $(kubectl get pods -n "${NIGHTLY_NS:-claude-pods}" -l app=claude-session                   --field-selector status.phase=Running                   -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    [ "$peer" = "$me" ] && continue
    if cred_ok "$peer"; then
      kubectl exec -n "${NIGHTLY_NS:-claude-pods}" "$peer" -- cat /home/node/.claude/.credentials.json 2>/dev/null         | kubectl exec -i -n "${NIGHTLY_NS:-claude-pods}" "$me" -- sh -c 'umask 077; cat > "$HOME/.claude/.credentials.json"' 2>/dev/null
      if cred_ok "$me"; then
        echo "credential: repaired from $peer" >&2
        return 0
      fi
    fi
  done
  echo "FATAL: no pod has a usable credential; run scripts/claude-pods-login.sh" >&2
  return 1
}

preflight_credential || exit 1

pick_model

now=$(date +%s)

for repo in $(tr ',' ' ' < /run/secrets/repos/pod2); do
  if [[ "$repo" != "$OWNER"/* ]]; then
    continue
  fi

  mapfile -t PRS < <(gh pr list --repo "$repo" --state open --json number,headRefName,updatedAt,headRefOid \
    --jq '.[] | select(.headRefName | startswith("fix/issue-")) | "\(.number) \(.updatedAt) \(.headRefOid)"' 2>/dev/null)
  [ "${#PRS[@]}" -eq 0 ] && continue

  for entry in "${PRS[@]}"; do
    read -r pr updated sha <<<"$entry"

    # Don't test a branch pod 0 may still be pushing to.
    upd=$(date -d "$updated" +%s 2>/dev/null || echo 0)
    if [ "$upd" -gt 0 ] && [ $(( (now - upd) / 60 )) -lt "$QUIET_MINUTES" ]; then
      echo "SKIP $repo#$pr: updated $(( (now - upd) / 60 ))m ago, still settling"
      continue
    fi

    name="$(basename "$repo")"
    dir="/workspace/$name"
    [ -d "$dir" ] || { echo "SKIP $repo#$pr: no clone"; continue; }
    git -C "$dir" fetch --quiet origin 2>/dev/null

    echo "--- testing $repo#$pr ($(date -Is))"
    # Inside the clone, which is the only directory --add-dir grants the
    # agent: $STATE_DIR is a sibling of it, so a verdict asked for there
    # could only be written by the agent reaching for a shell redirect.
    # Cleared first, because a file left by an earlier run would be read
    # as this run's verdict.
    VERDICT_FILE="$dir/.nightly-verdict"
    rm -f "$VERDICT_FILE"
    export dir repo pr VERDICT_FILE
    render_prompt "$PROMPT_DIR/test.md" > "$STATE_DIR/test-prompt.txt"

    out=$(timeout "$PER_PR_TIMEOUT" claude -p --model "$MODEL" \
      --permission-mode acceptEdits --settings "$NIGHTLY_SETTINGS" --add-dir "$dir" < "$STATE_DIR/test-prompt.txt")
    rc=$?
    printf '%s\n' "$out" | tail -25

    # The verdict gates the merge, so record it where pod 1 will look:
    # absence of a verdict must read as "not tested", never as "nothing
    # found".
    #
    # Read from a file the agent writes rather than found in what it
    # says: prose that discusses a verdict cannot be told from prose that
    # gives one. Anything but one of the three words is not a verdict.
    verdict=$(tr -d '[:space:]' < "$VERDICT_FILE" 2>/dev/null)
    case "$verdict" in
      PASS|FAIL|BLOCKED) ;;
      *) verdict="" ;;
    esac
    # Any abnormal exit, not only the timeout's 124: a crash or an
    # OOM kill ends the run just as incompletely, and the agent is not
    # around to say so.
    if [ $rc -ne 0 ]; then
      echo "ABNORMAL EXIT rc=$rc on $repo#$pr"
      verdict=""
    fi
    # Publish the verdict ON THE PR, not to local state: pod 1 runs in a
    # different pod with its own PVC and cannot read this filesystem.
    verdict="${verdict:-BLOCKED}"

    # A commit status, because it is the only channel that says WHICH
    # commit was tested - a label belongs to the pull request and
    # outlives the code it was about. A commit nothing has tested has no
    # status, which is the no-verdict path pod 1 already refuses.
    #
    # The SHA is the one read before the agent started, so a push during
    # the run is not credited with having been tested.
    case "$verdict" in
      PASS) state=success ;;
      FAIL) state=failure ;;
      *)    state=error ;;
    esac
    gh api -X POST "repos/$repo/statuses/$sha" \
      -f state="$state" -f context=nightly/integration \
      -f description="pod 2 integration test: $verdict" >/dev/null 2>&1 \
      || echo "   STATUS FAILED $repo#$pr $sha $state"
    # Also a label, for a human scanning the PR list. The status above
    # is what gates the merge.
    want="tested-$(printf '%s' "$verdict" | tr '[:upper:]' '[:lower:]')"
    gh label create "$want" --repo "$repo" --color ededed \
      --description "Nightly integration-test verdict from pod 2" >/dev/null 2>&1
    # Added before the others are removed, so a failure here leaves the
    # previous verdict standing rather than erasing it.
    if gh pr edit "$pr" --repo "$repo" --add-label "$want" 2>"$STATE_DIR/label-err"; then
      for l in tested-pass tested-fail tested-blocked; do
        [ "$l" = "$want" ] && continue
        gh pr edit "$pr" --repo "$repo" --remove-label "$l" >/dev/null 2>&1
      done
      echo "   labelled $repo#$pr $want"
      # Logged only once the PR carries it. This file is the only record
      # of the night, so it must not claim a verdict pod 1 cannot see.
      echo "$(date -Is) ${repo} ${pr} ${verdict}" >> "$STATE_DIR/tested-$(date +%Y%m%d)"
    else
      echo "   LABEL FAILED $repo#$pr $want: $(tr -d '\n' < "$STATE_DIR/label-err")"
    fi
    echo "--- $repo#$pr done rc=$rc verdict=${verdict:-BLOCKED}"

    # Leave no scratch tests behind: the next stage checks out this same
    # clone, and a stray failing file would be blamed on the PR.
    git -C "$dir" reset --hard --quiet 2>/dev/null
    git -C "$dir" clean -qfd 2>/dev/null
  done
done

echo "=== nightly-test complete $(date -Is) ==="
