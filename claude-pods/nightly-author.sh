#!/usr/bin/env bash
# Pod 0's nightly job: turn open GitHub issues into reviewed pull requests.
#
# Runs non-interactively via `claude -p`, so everything it needs must be in
# the prompt — there's nobody to answer a question at 00:00. It opens PRs and
# stops; merging is pod 1's job at 04:00, from a cold read of the diff.
#
# Driven by issues, not repos: most of the 24 clones are dormant hobby
# projects, and iterating repos would spend the night on ones with nothing
# to do.
set -uo pipefail

# Shared preamble for the three nightly pods — see lib/nightly-common.sh.
# A fix there reaches all three.
NIGHTLY_LIB="${NIGHTLY_LIB:-/usr/local/share/claude-pods/lib/nightly-common.sh}"
# shellcheck source=lib/nightly-common.sh
source "$NIGHTLY_LIB" || { echo "FATAL: cannot source $NIGHTLY_LIB" >&2; exit 1; }

MAX_TICKETS="${NIGHTLY_MAX_TICKETS:-3}"
ROUNDS="${NIGHTLY_ROUNDS:-3}"
PER_TICKET_TIMEOUT="${NIGHTLY_TICKET_TIMEOUT:-3600}"
LOG="$STATE_DIR/author-$(date +%Y%m%d).log"

mkdir -p "$STATE_DIR"
log_to "$LOG"
echo "=== nightly-author $(date -Is) model=$MODEL max=$MAX_TICKETS rounds=$ROUNDS ==="

require_gh_token || exit 1
require_kaneo_key || exit 1
preflight_credential || exit 1

# No board, no queue. Refuse rather than run: a pod that silently does
# nothing looks identical to one whose work all got skipped.
if ! kaneo_enrolled "$KANEO_PROJECT"; then
  echo "FATAL: project '$KANEO_PROJECT' is not enrolled; needs these columns: $KANEO_REQUIRED_COLUMNS" >&2
  exit 1
fi

pick_model

# Clear the sentinel up front: pod 1 keys off it, and a stale one from
# yesterday would let it review a half-finished run as if it were complete.
rm -f "$STATE_DIR/author-done"

# The To Do column, in the order the board shows it.
#
# To Do, not Backlog: Backlog is where everything lives, and nothing reads
# it. Moving a card into To Do is the dispatch — the moment someone says
# "work this one" — so a pod never picks up a ticket just because it was
# written down. Within To Do, position is priority, so dragging a card to
# the top is how you say "this one first".
#
# Emits one "<task-id> <repo>" per line. The repo comes from the card's
# repo: label; see kaneo_task_repo for why a card without exactly one is
# refused rather than guessed at.
collect_tickets() {
  local json
  json="$(kaneo task list --project "$KANEO_PROJECT" --status to-do \
            --sort position --order asc --limit 50 --json 2>/dev/null)" || return 0
  [ -z "$json" ] && return 0
  local n i task repo rc
  n="$(printf '%s' "$json" | jq 'length' 2>/dev/null)" || return 0
  i=0
  while [ "$i" -lt "${n:-0}" ]; do
    local card
    card="$(printf '%s' "$json" | jq -c ".[$i]")"
    task="$(printf '%s' "$card" | jq -r '.id')"
    repo="$(kaneo_task_repo "$card")"; rc=$?
    case $rc in
      0) printf '%s %s\n' "$task" "$repo" ;;
      1) echo "   SKIP $task: no repo: label" >&2 ;;
      2) echo "   SKIP $task: more than one repo: label" >&2 ;;
    esac
    i=$((i + 1))
  done
}

# SKIP lines go to stderr inside collect_tickets, so they reach the log
# without being mistaken for tickets here.
mapfile -t TICKETS < <(collect_tickets | head -n "$MAX_TICKETS")

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
  kaneo_move "$task" in-progress
  git -C "$dir" fetch --quiet origin 2>/dev/null
  git -C "$dir" checkout --quiet "$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||' || echo main)" 2>/dev/null
  git -C "$dir" reset --hard --quiet origin/HEAD 2>/dev/null

  # Fresh ticket or revision? Both arrive in To Do; the card's links are
  # what tells them apart. A card carrying an open PR was sent back by the
  # review panel, so it gets the rework prompt and pushes to the branch
  # that already exists — starting over would throw away the history the
  # panel's objection refers to.
  pr_url="$(kaneo_task_pr "$task")" && mode=rework || mode=author
  if [ "$mode" = rework ]; then
    pr="${pr_url##*/}"
    rounds_done="$(kaneo_rework_count "$task")"
    if [ "${rounds_done:-0}" -ge 2 ]; then
      # Not converging. A third attempt at the same objection is a card
      # bouncing between columns with nobody watching, so hand it over.
      echo "   $task declined $rounds_done times; sending to needs-human-review"
      kaneo_move "$task" needs-human-review
      kaneo_mention "$task" "${KANEO_OWNER:-chris}" \
        "the review panel has declined this $rounds_done times — it is not converging and wants a human"
      continue
    fi
    echo "   rework round $((rounds_done + 1)) on PR #$pr"
    export pr
  fi

  # Prompt lives in prompts/<mode>.md so it can be edited without touching
  # this script. Exported so render_prompt's subprocess can see them.
  export dir repo task ROUNDS
  render_prompt "$PROMPT_DIR/$mode.md" > "$STATE_DIR/prompt.txt"
  timeout "$PER_TICKET_TIMEOUT" claude -p --model "$MODEL" \
    --permission-mode acceptEdits --settings "$NIGHTLY_SETTINGS" \
    --add-dir "$dir" < "$STATE_DIR/prompt.txt"

  rc=$?
  # A timeout leaves the card in In Progress, deliberately. There is no
  # janitor sweeping stuck cards: the column is the signal, and a card
  # sitting in In Progress with no run behind it is visible on the board
  # and draggable back to To Do by hand. Automating that would mean
  # guessing when a long run is dead, and guessing wrong either kills
  # working runs or re-dispatches them alongside the original.
  [ $rc -eq 124 ] && echo "TIMEOUT after ${PER_TICKET_TIMEOUT}s on $t — card left in in-progress for a human to requeue"

  # The branch carries the task id, since there is no issue number.
  #
  # `.[0] // empty` matters: on an empty array `.[0]` is null, and
  # interpolating null yields the literal string "null null" with exit 0.
  # Without the guard, a ticket that produced no pull request took the
  # success path, attached a link to "null", and advanced the card to In
  # Review — which dispatches the test pod against a PR that does not exist.
  opened=$(gh pr list --repo "$repo" --head "$(kaneo_branch_for_task "$task")" --state open \
             --json number,url --jq '.[0] // empty | "\(.number) \(.url)"' 2>/dev/null)
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
    kaneo_move "$task" backlog
    kaneo_mention "$task" "${KANEO_OWNER:-chris}" \
      "the author pod produced no pull request for this card; parked in Backlog"
  else
    pr_num="${opened%% *}"
    pr_url="${opened#* }"
    kaneo_link_pr "$task" "$pr_url" open
    kaneo_move "$task" in-review
    echo "   PR #$pr_num linked to $task"
  fi

  echo "--- $t done rc=$rc"
done

date -Is > "$STATE_DIR/author-done"
echo "=== nightly-author complete $(date -Is) ==="
