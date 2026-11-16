#!/usr/bin/env bash
# dispatcher-command-protocol: 2
# Pod 0's stage: turn open GitHub issues into reviewed pull requests.
#
# Runs non-interactively via `claude -p`, so everything it needs must be in
# the prompt — there's nobody to answer a question at 00:00. It opens PRs and
# stops; merging is pod 1's job at 04:00, from a cold read of the diff.
#
# Driven by issues, not repos: most of the 24 clones are dormant hobby
# projects, and iterating repos would spend the night on ones with nothing
# to do.
set -uo pipefail

# Shared preamble for the three stage pods — see lib/pod-common.sh.
# A fix there reaches all three.
POD_LIB="${POD_LIB:-/usr/local/share/claude-pods/lib/pod-common.sh}"
# shellcheck source=lib/pod-common.sh
source "$POD_LIB" || { echo "FATAL: cannot source $POD_LIB" >&2; exit 1; }

require_dispatch_command "$@" || exit 1

MAX_TICKETS="${NIGHTLY_MAX_TICKETS:-3}"


LOG="$STATE_DIR/author-$(date +%Y%m%d).log"

mkdir -p "$STATE_DIR"
log_to "$LOG"
echo "=== stage-author $(date -Is) model=$MODEL max=$MAX_TICKETS ==="

require_gh_token || exit 1
require_dispatch_key || exit 1
take_pod_lock || exit 0
load_dispatch_command author || exit 1

# Prune on the way out, however this run ends. A stage that fails or
# times out is the one most likely to have filled the disk, so a tidy
# ending is exactly when this would not run.
trap prune_build_caches EXIT
warn_if_home_tight
preflight_credential || exit 1


# Clear the sentinel up front: pod 1 keys off it, and a stale one from
# yesterday would let it review a half-finished run as if it were complete.
rm -f "$STATE_DIR/author-done"

# Work only the dispatcher-assigned card.
TICKETS=("$ONLY_TASK $ONLY_REPO")

if [ "${#TICKETS[@]}" -eq 0 ]; then
  echo "no actionable open issues; nothing to do"
  date -Is > "$STATE_DIR/author-done"
  exit 0
fi
echo "tickets: ${TICKETS[*]}"

for t in "${TICKETS[@]}"; do
  task="${t%% *}"
  repo="${t#* }"
  case "$repo" in */*) ;; *) repo="$OWNER/$repo";; esac
  name="$(basename "$repo")"
  dir="/workspace/$name"
  [ -d "$dir" ] || { echo "SKIP $t: no clone at $dir"; continue; }

  echo "--- $t ($(date -Is))"
  # Moved before the work starts, not after: if this run dies mid-ticket the
  # card should read In Progress rather than sit in Backlog as though
  # nothing was attempted.
  kaneo_work_started "$task" stage-author || continue
  mode="$COMMAND_MODE"
  case "$mode" in
    advance) kaneo_outcome "$task" succeeded; continue ;;
    blocked)
      kaneo_mention "$task" "${KANEO_OWNER:-chris}" 'the review panel rework limit has been reached'
      kaneo_outcome "$task" blocked
      continue ;;
  esac
  prepare_command_checkout "$dir" || continue
  pick_model

  # Through the failover wrapper: a work account out of quota used to end
  # the ticket with the personal token mounted and unused.
  #
  # --output-format json because the wrapper reads terminal_reason to
  # decide that, rather than scraping the agent's prose. claude_result_text
  # pulls .result back out for the log.
  #
  # Known cost: the wrapper captures the output, so Loki shows nothing
  # until the run ends and a working long run looks like a hung one.
  # Restoring progress visibility means the caller supplying a sink, not
  # the wrapper teeing - a pipeline here replaces $? with tee's and
  # silently disables the failover.
  out=$(run_with_account_failover --stdin "$COMMAND_PROMPT" \
    timeout "$COMMAND_TIMEOUT" claude -p --output-format json --model "$MODEL" \
    --permission-mode acceptEdits --settings "$NIGHTLY_SETTINGS" \
    --add-dir "$dir")
  rc=$?
  printf '%s\n' "$(claude_result_text "$out")"

  # Belt and braces on the push, the same way the old flow verified the
  # issue link: the prompt asks for a push after each round, but a prompt
  # is not a guarantee and the agent may have been cut off before it got
  # there. Commits that exist only in this clone die with the pod, and the
  # next ticket resets this checkout to origin — so unpushed work is lost
  # even when nothing is wrong with it.
  #
  # One run reached review round 2 of 3 on a 3,000-line change, hit a
  # usage limit, and left every commit local.
  branch="$(kaneo_branch_for_task "$task")"
  if git -C "$dir" rev-parse --verify --quiet "$branch" >/dev/null 2>&1; then
    ahead="$(git -C "$dir" rev-list --count "origin/HEAD..$branch" 2>/dev/null || echo 0)"
    if [ "${ahead:-0}" -gt 0 ]; then
      if git -C "$dir" push -u origin "$branch" >/dev/null 2>&1; then
        echo "   pushed $branch ($ahead commit(s)) — work is safe even if this run stopped early"
      else
        echo "   FAILED to push $branch; $ahead commit(s) exist only in this pod" >&2
      fi
    fi
  fi

  # A timeout leaves the card in In Progress, deliberately. There is no
  # janitor sweeping stuck cards: the column is the signal, and a card
  # sitting in In Progress with no run behind it is visible on the board
  # and draggable back to To Do by hand. Automating that would mean
  # guessing when a long run is dead, and guessing wrong either kills
  # working runs or re-dispatches them alongside the original.
  [ $rc -eq 124 ] && echo "TIMEOUT after ${COMMAND_TIMEOUT}s on $t — card left in in-progress for a human to requeue"

  # Use the same exact-task, same-repository selection as recovery/review.
  opened=$(command_pr | jq -r '"\(.number) \(.url)"')
  if [ -z "$opened" ]; then
    # No PR is a legitimate outcome — the card may have turned out to be
    # unworkable — but it must not stay in In Progress claiming work is
    # underway once this run is over.
    #
    # Back to Backlog, NOT To Do. A move to To Do is what dispatches the
    # author, so returning a failed ticket there would re-dispatch it
    # instantly, fail the same way, and do it again: a machine-driven
    # retry loop with no human in it and nothing to slow it down. Backlog
    # is inert, so the card lands somewhere visible and stops. Dragging it
    # back to To Do is then a deliberate "try again".
    echo "   no PR for $task; parking the card in backlog"
    kaneo_outcome "$task" failed
    kaneo_mention "$task" "${KANEO_OWNER:-chris}" \
      "the author pod produced no pull request for this card; parked in Backlog"
  else
    pr_num="${opened%% *}"
    pr_url="${opened#* }"
    kaneo_link_pr "$task" "$pr_url" open
    kaneo_outcome "$task" succeeded
    echo "   PR #$pr_num linked to $task"
  fi

  echo "--- $t done rc=$rc"
done

date -Is > "$STATE_DIR/author-done"
echo "=== stage-author complete $(date -Is) ==="
