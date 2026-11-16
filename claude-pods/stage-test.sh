#!/usr/bin/env bash
# dispatcher-command-protocol: 2
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

# Shared preamble for the three stage pods — see lib/pod-common.sh.
# A fix there reaches all three.
POD_LIB="${POD_LIB:-/usr/local/share/claude-pods/lib/pod-common.sh}"
# shellcheck source=lib/pod-common.sh
source "$POD_LIB" || { echo "FATAL: cannot source $POD_LIB" >&2; exit 1; }

require_dispatch_command "$@" || exit 1


QUIET_MINUTES="${NIGHTLY_QUIET_MINUTES:-30}"
LOG="$STATE_DIR/test-$(date +%Y%m%d).log"

mkdir -p "$STATE_DIR"
log_to "$LOG"
echo "=== stage-test $(date -Is) ==="

require_gh_token || exit 1
require_dispatch_key || exit 1
take_pod_lock || exit 0
load_dispatch_command test || exit 1

# Prune on the way out, however this run ends. A stage that fails or
# times out is the one most likely to have filled the disk, so a tidy
# ending is exactly when this would not run.
trap prune_build_caches EXIT
warn_if_home_tight
preflight_credential || exit 1

pick_model

# Start acknowledgment precedes GitHub work; the dispatcher validates the
# command's current task, repository, stage and column visit.
kaneo_work_started "$ONLY_TASK" stage-test || exit 1
for repo in "$ONLY_REPO"; do
  PRS=("$(jq -r '"\(.pr) \(.headSHA)"' "$COMMAND_PAYLOAD")")
  for entry in "${PRS[@]}"; do
    read -r pr sha <<<"$entry"
    task="$ONLY_TASK"

    name="$(basename "$repo")"
    dir="/workspace/$name"
    [ -d "$dir" ] || { echo "SKIP $repo#$pr: no clone"; continue; }
    prepare_command_checkout "$dir" || continue

    echo "--- testing $repo#$pr ($(date -Is))"
    # Inside the clone, so git clean sweeps it at the end of the loop
    # and the agent is never pointed at $STATE_DIR, where the log of its
    # own run lives. Cleared first, because a file left by an earlier
    # run would be read as this run's verdict.
    # prompts/test.md tells the agent this same path.
    VERDICT_FILE="$dir/.nightly-verdict"
    rm -f "$VERDICT_FILE"


    # Through the failover wrapper: a work account at its limit otherwise
    # ends the run with no verdict, which stage-merge correctly reads as
    # "not tested" and the card lands in needs-human-review. The personal
    # token was mounted and unused. This stage already captured the output,
    # so the wrapper changes nothing else.
    out=$(run_with_account_failover --stdin "$COMMAND_PROMPT" \
      timeout "$COMMAND_TIMEOUT" claude -p --output-format json --model "$MODEL" \
      --permission-mode acceptEdits --settings "$NIGHTLY_SETTINGS" --add-dir "$dir")
    rc=$?
    if [ "$(git -C "$dir" rev-parse HEAD)" != "$sha" ]; then
      echo 'worker checkout changed during execution; refusing its verdict' >&2
      kaneo_outcome "$ONLY_TASK" blocked
      continue
    fi
    out_text=$(claude_result_text "$out")
    printf '%s\n' "$out_text" | tail -25 | redact

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

    # Posted by the script, not left to the agent: pod 1 tells a human to
    # read pod 2's comment, and an agent that died or chose not to
    # comment would leave them reading nothing. The last of the output is
    # what it was doing when it stopped.
    # Four backticks: the agent's own output may contain a three-backtick
    # fence, which would close the wrapper early.
    gh pr comment "$pr" --repo "$repo" --body "$(printf 'Nightly integration test (pod 2): **%s** for `%s`.\n\n<details><summary>what it reported</summary>\n\n````\n%s\n````\n\n</details>' \
      "$verdict" "${sha:0:7}" "$(printf '%s' "$out_text" | tail -40 | redact)")" >/dev/null 2>&1 \
      || echo "   COMMENT FAILED $repo#$pr"
    # Advance the card. PASS moves to Mergeable, which is what dispatches
    # the review panel — the commit status above is the gate, this move is
    # the trigger. FAIL and BLOCKED go back to To Do carrying the PR, so
    # the author picks them up in rework mode rather than starting over.
    task="$(kaneo_task_for_pr "$repo" "$pr")" || task=""
    case "$verdict" in
      PASS)
        # CI must be green before the panel sees it. The panel costs a full
        # agent run and most of an hour; spending that on a branch whose
        # own tests are failing wastes it, and a reviewer reading a red
        # diff is being asked the wrong question. CI is also the only
        # signal in this pipeline that no agent produced, so it belongs
        # ahead of the agents, not after them.
        ci=$(gh pr checks "$pr" --repo "$repo" 2>&1)
        if printf '%s' "$ci" | grep -qiE '\b(fail|failure|error)\b'; then
          kaneo_requeue "$task" "CI is red on \`${sha:0:7}\` — see PR #$pr"
        elif printf '%s' "$ci" | grep -qiE '\b(pending|in_progress|queued)\b'; then
          # Left in In Review on purpose: CI will finish on its own, and
          # the card is already where a re-run would pick it up. Moving it
          # anywhere would either lose it or dispatch work twice.
          echo "   CI still running on $repo#$pr; leaving the card in in-review"
        else
          kaneo_outcome "$task" succeeded
        fi
        ;;
      FAIL)
        kaneo_requeue "$task" "integration testing failed on \`${sha:0:7}\` — see PR #$pr"
        ;;
      *)
        # BLOCKED is not a verdict about the code — the pod could not run
        # it at all — so this wants a person, not another attempt.
        [ -n "$task" ] && kaneo_mention "$task" "${KANEO_OWNER:-chris}" \
          "integration testing could not run against \`${sha:0:7}\` (will not build, or needs something the pod does not have)"
        kaneo_outcome "$task" blocked
        ;;
    esac
    echo "--- $repo#$pr done rc=$rc verdict=${verdict:-BLOCKED}"

    # Leave no scratch tests behind: the next stage checks out this same
    # clone, and a stray failing file would be blamed on the PR.
    git -C "$dir" reset --hard --quiet 2>/dev/null
    git -C "$dir" clean -qfd 2>/dev/null
  done
done

echo "=== stage-test complete $(date -Is) ==="
