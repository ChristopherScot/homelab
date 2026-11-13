#!/usr/bin/env bash
# The preamble the three stage scripts share: stage-author (pod 0),
# stage-test (pod 2) and stage-merge (pod 1) each source this before
# doing anything of their own.
#
# One copy, because three copies held in step by hand did not stay in
# step: a helper added to one pod's script missed the others, and a fix
# to the credential preflight meant the same edit in three files (#59).
# Anything every pod needs lives here; anything one pod needs lives in
# its script.
#
# Sourced, never run. Sourcing it defines defaults and functions and does
# nothing else — no output, no exec, no exit — so a test can source it
# too. The image ships it at /usr/local/share/claude-pods/lib/ and the
# scripts find it through POD_LIB.
#
# The scripts then call, in this order: log_to (before anything prints,
# or it is lost to Loki), require_gh_token, preflight_credential, and
# only then pick_model — its probe cannot tell a capped model from a dead
# credential, so the credential has to be known good first.
#
# The defaults below are set for the scripts that source this file; read
# on its own, some of them look unused to a linter.
# shellcheck disable=SC2034

# Namespace the session pods run in; preflight_credential looks for
# peers here.
NIGHTLY_NS="${NIGHTLY_NS:-claude-pods}"
# Only repos under this GitHub owner are worked on; each pod's repo list
# is filtered to it.
OWNER="${NIGHTLY_OWNER:-ChristopherScot}"
# Per-run state and logs, on the pod's PVC.
STATE_DIR="${NIGHTLY_STATE_DIR:-/workspace/.nightly}"

# --- Model -----------------------------------------------------------------
# Preferred model, with a fallback. Fable is first choice, but it sits
# behind a monthly spend cap that Opus does not — and a capped model fails
# every ticket with "You've hit your monthly spend limit" rather than
# degrading. Probed once per run so the job starts using Fable again by
# itself when the cap resets, instead of needing an edit.
MODEL="${NIGHTLY_MODEL:-claude-fable-5-1}"
MODEL_FALLBACK="${NIGHTLY_MODEL_FALLBACK:-opus}"
# Probes MODEL once; if the reply says it is capped or unavailable, sets
# MODEL to MODEL_FALLBACK (which is not probed). Reports the choice on
# stderr.
pick_model() {
  local probe
  probe=$(cd /workspace && timeout 120 claude -p --model "$MODEL" "Reply with exactly: OK" 2>&1 | tail -2)
  if printf '%s' "$probe" | grep -qiE "spend limit|rate limit|not support this model|unavailable"; then
    echo "model $MODEL unavailable ($(printf '%s' "$probe" | head -1)); falling back to $MODEL_FALLBACK" >&2
    MODEL="$MODEL_FALLBACK"
  fi
  echo "using model: $MODEL" >&2
}

# --- Prompts ---------------------------------------------------------------
# Prompts live as plain files so they can be edited and reviewed on their
# own. Expand $VAR references in them without running the text through a
# shell — the prompts contain backticks and quotes, and `eval` on them
# would be both fragile and an injection path from issue titles.
PROMPT_DIR="${NIGHTLY_PROMPT_DIR:-/usr/local/share/claude-pods/prompts}"
# acceptEdits allows file edits but NOT shell commands, so without an
# explicit allow-list every gh / go test / kubectl call stops for an
# approval nobody is there to give. Scoped list, not bypassPermissions.
NIGHTLY_SETTINGS="${NIGHTLY_SETTINGS:-/usr/local/share/claude-pods/prompts/nightly-settings.json}"
# render_prompt FILE: prints FILE with its $VAR references expanded from
# the environment; a $VAR that is not set is left as written. Exits the
# script if FILE is unreadable: with no prompt, every ticket would fail
# the same way.
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

# --- Where the run's output goes -------------------------------------------
# log_to FILE: from here on, everything the script prints goes to FILE on
# the PVC AND to pid 1's stdout, so the run shows up in Loki.
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
log_to() {
  local log="$1"
  if [ -w /proc/1/fd/1 ]; then
    exec > >(tee -a "$log" > /proc/1/fd/1) 2>&1
  else
    exec > >(tee -a "$log") 2>&1
  fi
}

# --- GitHub ----------------------------------------------------------------
# Exports GH_TOKEN from the Vault-mounted secret; fails if there is none,
# since every gh call after this would.
require_gh_token() {
  GH_TOKEN="$(cat /run/secrets/git/token 2>/dev/null)"
  export GH_TOKEN
  if [ -z "$GH_TOKEN" ]; then echo "FATAL: no GitHub token" >&2; return 1; fi
}

# Takes GH_TOKEN out of agent output before it is quoted anywhere public.
#
# The agent inherits GH_TOKEN so it can run gh, and the allow-list lets it
# run env and cat. Its output reaches pull requests on public repos, so
# the token is removed rather than trusted not to appear. Safe for a
# GitHub token because those are [A-Za-z0-9_]; a secret containing a
# backslash or the sed delimiter would need another way.
#
# Call require_gh_token first: with GH_TOKEN unset this passes its input
# through unchanged.
redact() {
  if [ -n "$GH_TOKEN" ]; then
    sed "s|$GH_TOKEN|[redacted]|g"
  else
    cat
  fi
}

# Wraps agent output for a public pull request. Unfenced, its markdown
# renders: a bare @name notifies that person, and #52 cross-links an
# issue back to this PR. Four backticks, because the agent's own output
# may contain a three-backtick fence.
fence() {
  printf '````\n%s\n````' "$(printf '%s' "$1" | tail -30 | redact)"
}

# Lands PR $2 (number or URL) in repo $1 (owner/name) and deletes its
# branch; exit status is gh's. Merge method is per-repo and squash is
# disabled across all of these, so asking for it unconditionally fails
# every merge ("Squash merges are not allowed on this repository"):
# squash if allowed, else a merge commit if allowed, else rebase (also
# the fallback when the repo's settings cannot be read). gh's stderr is
# deliberately not discarded: the reason for a refusal belongs in the log.
merge_pr() {
  local repo="$1" pr="$2" sha="${3:-}" method
  case "$(gh api "repos/$repo" --jq '"\(.allow_squash_merge) \(.allow_merge_commit)"' 2>/dev/null)" in
    "true "*) method=--squash ;;
    *" true") method=--merge ;;
    *)        method=--rebase ;;
  esac
  # With a SHA, the merge is refused if the branch moved since that
  # commit was judged. Without one — reverts, whose PR is seconds old and
  # has no verdict to be stale — there is nothing to pin to.
  if [ -n "$sha" ]; then
    gh pr merge "$pr" --repo "$repo" "$method" --match-head-commit "$sha" --delete-branch >/dev/null
  else
    gh pr merge "$pr" --repo "$repo" "$method" --delete-branch >/dev/null
  fi
}

# Undo merged PR $2 in repo $1 after it turned main red. `gh pr revert`
# only OPENS a revert pull request — it has no flag to land it — so
# landing it is a second, explicit step through merge_pr, the same way
# the original went in. Pushing a revert commit straight to main is not
# an alternative: the nightly-guard ruleset on these repos requires every
# change to main to arrive through a pull request.
#
# Prints nothing and exits non-zero if the revert PR could not be opened.
# Otherwise prints its URL as soon as it exists, then exits non-zero if
# it could not be merged — it is left open, and the URL lets the caller
# point the morning human at it.
revert_pr() {
  local repo="$1" pr="$2" url
  url=$(gh pr revert "$pr" --repo "$repo" \
          --body "Reverts #$pr. Opened by stage-merge because main's CI went red after it landed.") \
    || return 1
  echo "$url"
  # GitHub works out a new PR's mergeability in the background, and a
  # merge asked for before that finishes is refused as "not mergeable"
  # although nothing is wrong. This PR is seconds old, so allow a few
  # tries before calling it failed. (The sleep is an env knob only so the
  # test's permanent-failure case does not wait a minute.)
  local _
  for _ in 1 2 3 4 5 6; do
    merge_pr "$repo" "$url" && return 0
    sleep "${NIGHTLY_REVERT_RETRY_SLEEP:-10}"
  done
  return 1
}

# --- Claude credential -----------------------------------------------------
# In its own file so the desloppify image can take the account helpers
# without the kubectl and Kaneo machinery below.
# shellcheck source=claude-account.sh
. "$(dirname "${BASH_SOURCE[0]}")/claude-account.sh"

# One stage at a time in this pod.
#
# The three stages share a clone per repository and a single fixed
# $STATE_DIR/prompt.txt, so two runs in one pod race: the second writer
# wins and a ticket gets the other one's prompt.
#
# Taken here rather than tracked by the dispatcher, because the run is
# detached and outlives the exec that launched it — anything the dispatcher
# held in memory would be released the moment the launch returned, and
# would be lost entirely on a restart. The lock lives with the thing it
# protects.
#
# TWO readers probe it with `flock -n <path> true`, both hardcoding
# /tmp/nightly.lock: the dispatcher before launching a stage
# (dispatch.mjs podIsBusy) and the session-sleep cron before scaling the
# pods to 0. The stakes differ: a dispatcher misread starts a duplicate
# agent; a reaper misread TERMINATES a live run as "idle". So the
# NIGHTLY_LOCK override below must never be set in a session pod — a run
# holding a different path is invisible to both readers.
take_pod_lock() {
  exec 9>"${NIGHTLY_LOCK:-/tmp/nightly.lock}"
  if ! flock -n 9; then
    echo "another nightly stage is already running in this pod; exiting" >&2
    return 1
  fi
}

# --- Kaneo -----------------------------------------------------------------
# The board at kaneo.home.chrisscotmartin.com IS the work queue. Chris files
# tickets there, the pods move them through the columns, and a card in
# Needs Human Review is how a human gets asked for a decision.
#
# GitHub issues are no longer a work source. The pods still use GitHub for
# everything issues were not — branches, pull requests, CI, commit statuses —
# but what to work on comes from the board and nowhere else.
#
# Everything here wraps the upstream `kaneo` CLI rather than curl+jq against
# the REST API: the CLI ships with the server, so a schema change arrives as
# a CLI upgrade instead of as a silently empty jq filter at 2am.
KANEO_PROJECT="${KANEO_PROJECT:-claude-pods}"

# The columns a project must have before the pods will touch it. More
# is fine — a project may carry extra columns of its own — but each of these
# has to exist, because each is a destination something below moves a card
# to, or the queue the author pod reads.
#
# Backlog and To Do are deliberately different things. Backlog is where
# everything lives; nothing reads it. Moving a card to To Do is the
# dispatch — an explicit "work this one" — so a pod never starts on
# something just because it was written down.
KANEO_REQUIRED_COLUMNS="backlog to-do in-progress in-review needs-human-review mergeable done"

# The branch a card's work lives on.
#
# One fact, one place. This convention is the join between a pull request
# and the card it came from, and it is read by four things: the author
# (creating it), the author prompt (told to use it), kaneo_task_for_pr
# (parsing it back), and the PR filters in the test and merge pods. It was
# previously written out at each of those sites, and when the prefix changed
# from fix/issue-<n> to fix/<task> two of them were missed — so the test and
# merge pods matched nothing and every card stopped dead in In Review while
# the logs read rc=0.
KANEO_BRANCH_PREFIX="${KANEO_BRANCH_PREFIX:-fix/}"
# Exported: the PR filters in the test and merge pods read it as
# $ENV.KANEO_BRANCH_PREFIX inside a jq expression.
export KANEO_BRANCH_PREFIX
kaneo_branch_for_task() { printf '%s%s' "$KANEO_BRANCH_PREFIX" "$1"; }

# The pipeline, written down once.
#
# The dispatcher decides which columns START work; these scripts decide
# which columns they may move a card TO. Both halves are the same graph, and
# with only one half visible it is impossible to see a cycle. Keep this in
# step with ROUTES in dispatcher/dispatch.mjs.
#
#   backlog             inert — holding area, nothing reads it
#   to-do        -> author  -> in-progress -> {in-review, backlog*, needs-human-review}
#   in-review    -> test    -> {mergeable, to-do(+), needs-human-review}
#   mergeable    -> merge   -> {done, needs-human-review, to-do(+)}
#   in-progress  no column dispatches FROM it, but the hourly reconcile
#       re-dispatches the author for any card STALE there (the author
#       moves the card first and works second, so a death in between
#       strands it — CLA-15, 2026-11-10). The author's own mode logic
#       then decides: advance an unreviewed PR, rework, resume, or redo.
#   needs-human-review  inert — waiting on a person
#   done                inert — terminal, except a revert reopens to to-do(+)
#
#   (*) backlog is inert ON PURPOSE for the failure path: sending a failed
#       card to to-do would re-dispatch the author instantly and loop with
#       no human in it.
#   (+) the only backward edges, and the only cycles in the graph. Each is
#       capped by kaneo_rework_count; without that cap a card can bounce
#       between to-do and in-review forever, machine-driven.

# Reads KANEO_API_KEY the way require_gh_token reads the git token. Fatal,
# like that one: with no board there is no queue, and a pod with nothing to
# work on should say so rather than appear to run successfully.
require_kaneo_key() {
  KANEO_API_KEY="$(cat /run/secrets/kaneo/api-key 2>/dev/null)"
  # In-cluster Service, not the public hostname: cluster DNS does not
  # resolve *.home.chrisscotmartin.com, so the pods got ENOTFOUND and every
  # run died at the enrolment check. The dispatcher hit this first and was
  # pointed at the Service for the same reason; this is the other half.
  #
  # It also keeps a run that never leaves the cluster from depending on the
  # LAN's DNS and the ingress being healthy.
  KANEO_API_URL="${KANEO_API_URL:-http://kaneo.kaneo.svc.cluster.local:5173}"
  # Where a HUMAN opens the board. The Service URL above is unroutable
  # outside the cluster, so a card link built from it in a pull request
  # body would be dead for everyone who reads it.
  KANEO_WEB_URL="${KANEO_WEB_URL:-https://kaneo.home.chrisscotmartin.com}"
  export KANEO_API_KEY KANEO_API_URL KANEO_WEB_URL
  # Both blockers in one pass: preflight exists so a single restart
  # surfaces everything that is wrong, not the first thing.
  local bad=0
  [ -n "$KANEO_API_KEY" ] || { echo "FATAL: no Kaneo API key at /run/secrets/kaneo/api-key" >&2; bad=1; }
  command -v kaneo >/dev/null 2>&1 || { echo "FATAL: kaneo CLI not installed" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

# True when a project carries every required column. This is the enrolment switch:
# a project that has them is worked, one that does not is left alone, and
# nothing anywhere lists which projects are live. The board is the config.
#
# Silent when a project has NONE of the required columns — that is a project
# deliberately kept out of this flow, and a nightly line about it would be
# noise that teaches you to skim the log. A project with SOME of them is
# likely a typo or a renamed column, so that one says what is missing.
kaneo_enrolled() {
  local project="${1:-$KANEO_PROJECT}" have missing want total found=0
  have="$(kaneo column list --project "$project" --jq '.[].slug' 2>/dev/null)"
  # The CLI prints a JSON error object and still exits 0 — a DNS blip or an
  # expired key comes back as {"error":"..."} rather than a failure. Trusting
  # the exit status alone turns "I could not reach the board" into "this
  # project has no columns", which is indistinguishable from a project
  # deliberately left out of the flow, and would silently un-enrol
  # everything during an outage.
  case "$have" in
    '') echo "kaneo: no answer listing columns for $project" >&2; return 1 ;;
    '{"error"'*|*'"error":'*) echo "kaneo: cannot read columns for $project: $have" >&2; return 1 ;;
  esac

  missing=""
  for want in $KANEO_REQUIRED_COLUMNS; do
    if printf '%s\n' "$have" | grep -qx "$want"; then
      found=$((found + 1))
    else
      missing="$missing $want"
    fi
  done

  [ -z "$missing" ] && return 0
  total=$(printf '%s\n' $KANEO_REQUIRED_COLUMNS | grep -c .)
  [ "$found" -gt 0 ] && echo "kaneo: SKIP $project — $found/$total columns, missing:$missing" >&2
  return 1
}

# Moves a card to a column by slug. Never fatal: the board is a view of the
# night's work, and failing to update it must not stop the work itself. A
# failed move is logged so a stale card is explainable in the morning.
kaneo_move() {
  local task="$1" to="$2"
  # Audible. A merged PR whose branch is not <prefix><task> has no card to
  # move, and silence here leaves it sitting in Mergeable with nothing
  # anywhere saying why.
  [ -n "$task" ] || { echo "   kaneo: no card for this PR; not moved to $to" >&2; return 0; }
  # `task status`, not `task move`: move is for sending a card to another
  # PROJECT and fails with "there is no other project to move it to" on a
  # single-project workspace. Every column change the pipeline makes went
  # through that failing path, so the board never advanced past To Do even
  # when the work ran.
  if kaneo task status "$task" "$to" >/dev/null 2>&1; then
    echo "   kaneo: $task -> $to"
  else
    echo "   kaneo: FAILED to move $task -> $to" >&2
  fi
}

# Attaches a pull request to a card, so it shows the PR and its state without
# Kaneo needing a GitHub App installed. The card is the only record of why a
# PR exists — there is no issue behind it — so this link is what makes the
# work explicable later.
# The CLI attaches a plain link; `resourceType: pull_request` with its
# open/merged badge is REST-only, and not worth a second code path for a
# badge. The URL is a PR URL either way, which is what makes the card
# explicable later.
kaneo_link_pr() {
  local task="$1" url="$2" title="${3:-pull request}"
  [ -n "$task" ] || return 0
  # Adding the same link twice is not harmless: the card ends up listing
  # one pull request several times, and a re-run is exactly when that
  # happens. Checked rather than assumed, because the CLI has no upsert.
  if kaneo task link list "$task" --jq ".[].url" 2>/dev/null | grep -qxF "$url"; then
    return 0
  fi
  kaneo task link add "$task" "$url" --title "$title" \
    >/dev/null 2>&1 || echo "   kaneo: FAILED to link $url to $task" >&2
}

# Posts a comment and @-mentions a human.
#
# Load-bearing rather than decorative: Kaneo has no per-column notification
# filter (taskStatusChangeEnabled is one boolean covering every column), so
# status notifications are off and this mention is the ONLY thing that
# reaches a phone. A RISKY verdict nobody is told about is a card in a column
# nobody is watching, so a failure here is reported loudly, not swallowed.
kaneo_mention() {
  local task="$1" who="$2" body="$3"
  # Non-zero, not silent: the comment below calls this the only channel
  # that reaches a phone, so "there was no card to mention on" has to be
  # as loud as "the mention failed".
  [ -n "$task" ] || { echo "   kaneo: no card to mention on — nobody has been notified" >&2; return 1; }
  if kaneo task comment "$task" "@$who $body" >/dev/null 2>&1; then
    echo "   kaneo: mentioned @$who on $task"
  else
    echo "   kaneo: MENTION FAILED on $task — nobody has been notified" >&2
    return 1
  fi
}

# The repo a card is for, from its repo:<name> label.
#
# A Kaneo-native card has no GitHub issue to infer a repo from, so the label
# is the only place that fact lives. Zero labels means nowhere to do the
# work; two means the card does not say where. Both are refused rather than
# guessed at — printing the reason, because unlike a non-enrolled project
# this is always a mistake.
kaneo_task_repo() {
  local json="$1" repos
  repos="$(printf '%s' "$json" | jq -r '[.labels[]?.name | select(startswith("repo:")) | sub("^repo:"; "")] | .[]' 2>/dev/null)"
  case "$(printf '%s' "$repos" | grep -c .)" in
    1) printf '%s' "$repos" ;;
    0) return 1 ;;
    *) return 2 ;;
  esac
}

# Work pushed for this card that never reached a pull request.
#
# A run can stop between its first commit and `gh pr create` — a usage
# limit, a timeout, a node going away — and then the branch exists on the
# remote with real work on it while the card looks untouched. Without
# this the next run checks out main, resets hard, and starts the ticket
# over, abandoning what was already done.
#
# Prints the number of commits the branch is ahead of the default branch,
# or returns 1 when there is no such branch.
kaneo_unfinished_branch() {
  local repo="$1" task="$2" branch ahead
  branch="$(kaneo_branch_for_task "$task")"
  git ls-remote --exit-code --heads "https://github.com/$repo" "$branch" >/dev/null 2>&1 || return 1
  ahead="$(gh api "repos/$repo/compare/HEAD...$branch" --jq .ahead_by 2>/dev/null)"
  case "$ahead" in
    ''|*[!0-9]*) return 1 ;;
    0) return 1 ;;
    *) printf '%s' "$ahead" ;;
  esac
}

# The open pull request already attached to a card, if there is one.
#
# This is what tells a fresh ticket from a revision. Both arrive in To Do —
# there is no separate rework column, because "a pod should work this" is
# one state whether or not it has been tried before — so the card's own
# links are the thing that says which. A card with a PR gets the rework
# prompt and pushes to the existing branch; a card without gets the author
# prompt and starts one.
#
# Prints the PR url and returns 0, or returns 1 when there is none.
kaneo_task_pr() {
  local task="$1" url
  [ -n "$task" ] || return 1
  url="$(kaneo task link list "$task" --jq '[.[] | .url | select(test("/pull/[0-9]+$"))] | first // empty' 2>/dev/null)"
  [ -n "$url" ] || return 1
  printf '%s' "$url"
}

# The one headline every requeue writes, and the one kaneo_rework_count
# reads. A literal shared by a writer and a reader in different files is a
# fact with two homes; naming it gives it one.
KANEO_REWORK_HEADLINE="Sent back for rework"

# Sends a card back to To Do, counted.
#
# BOTH requeue paths go through here — the review panel's NO-MERGE and the
# integration test's FAIL. That matters: the cap below counts these
# comments, and when the test path commented in its own words it was
# invisible to the counter, so a card could bounce to-do -> in-review ->
# to-do forever with the count stuck at zero. Every bounce must be written
# the same way or the cap is decorative.
kaneo_requeue() {
  local task="$1" why="$2"
  [ -n "$task" ] || { echo "   kaneo: no card to requeue" >&2; return 1; }
  kaneo task comment "$task" "$KANEO_REWORK_HEADLINE: $why" >/dev/null 2>&1 \
    || echo "   kaneo: FAILED to record the requeue on $task" >&2
  kaneo_move "$task" to-do
}

# How many times a card has been sent back.
#
# Counted on the CARD, not on the pull request: the card is the thing that
# bounces, it survives a force-push, and both requeue paths touch it while
# only one of them touches the PR.
#
# Two is the cap. A card the pipeline keeps rejecting is not converging,
# and the third attempt should reach a person instead of going round again.
kaneo_rework_count() {
  local task="$1" n
  [ -n "$task" ] || { echo 0; return; }
  # `task view --full`, because `task comment` only posts — there is no
  # list subcommand, and --full is what returns every comment rather than
  # the latest three.
  # Read the card whole, then count locally. Asking the CLI to both fetch
  # and filter hides the difference between "no matching comments" and "the
  # request failed": a rate-limited or unreachable call prints
  # {"error":...}, exits 0, and the jq count comes back 0 — which would
  # fail OPEN and uncap the retry loop, the exact failure this cap exists
  # to prevent.
  local raw
  raw="$(kaneo task view "$task" --full --json 2>/dev/null)"
  case "$raw" in
    ''|*'"error":'*)
      echo "   kaneo: cannot read $task (${raw:-no answer}); treating as capped" >&2
      echo 99; return ;;
  esac
  n="$(printf '%s' "$raw" | jq "[.comments[]?.content | select(startswith(\"$KANEO_REWORK_HEADLINE\"))] | length" 2>/dev/null)"
  # An empty answer is a failed lookup, not zero bounces. Defaulting it to
  # 0 would fail open and uncap the loop silently, so say so and assume the
  # cap is reached — refusing to retry is the safe direction.
  case "$n" in
    ''|*[!0-9]*) echo "   kaneo: cannot read rework count for $task; treating as capped" >&2; echo 99 ;;
    *) echo "$n" ;;
  esac
}

# The card a pull request belongs to.
#
# The merge pod works from pull requests, but the board works from cards, so
# something has to join them. The branch carries the task id (fix/<task>),
# which is the one place the link survives a force-push, a retitle and an
# edited PR body.
kaneo_task_for_pr() {
  local repo="$1" pr="$2" head
  head="$(gh pr view "$pr" --repo "$repo" --json headRefName --jq .headRefName 2>/dev/null)"
  # Uses KANEO_BRANCH_PREFIX, not a literal fix/: this is the inverse of
  # kaneo_branch_for_task and the two must agree. A literal here would keep
  # working on the default and silently stop finding cards the moment the
  # prefix was changed anywhere else.
  case "$head" in
    "$KANEO_BRANCH_PREFIX"*) printf '%s' "${head#"$KANEO_BRANCH_PREFIX"}" ;;
    *) return 1 ;;
  esac
}

# Sends a declined pull request back to To Do with the panel's reasoning.
#
# The full verdict stays on the pull request — it can be long, and the
# rework agent reads it there — while the card gets the first few lines,
# which is what a person scanning the board needs. The move and the count
# are kaneo_requeue's, so this path is counted like the test path.
kaneo_note_and_requeue() {
  local repo="$1" pr="$2" verdict="$3" task summary
  task="$(kaneo_task_for_pr "$repo" "$pr")" || {
    echo "   kaneo: no card for $repo#$pr (branch is not ${KANEO_BRANCH_PREFIX}<task>); not requeued" >&2
    return 1
  }
  summary="$(printf '%s' "$verdict" | grep -v '^VERDICT:' | sed '/^[[:space:]]*$/d' | head -6)"
  kaneo_requeue "$task" "the review panel declined PR #$pr

$summary"
}

# prune_build_caches
# Drop the regenerable package and build caches from $HOME.
#
# These pods ran out of disk on 2026-11-12 and the failure was not an
# obvious one: pod2's home hit 100%, Claude Code could not write its
# session transcript (ENOSPC), the agent exited non-zero AFTER
# completing its work and reaching a PASS verdict, and stage-test read
# that exit code as "the pod could not run this" and parked the card in
# needs-human-review as BLOCKED. A full disk therefore looks like a
# broken ticket, not like a full disk.
#
# What fills it is entirely regenerable - on pod2, go/pkg 1.9G,
# .npm 1.8G and .cache/go-build 1.2G against .claude at 99M. The stage
# scripts do not invoke go themselves, but the prompts they render do
# (author.md and review.md both say `go test ./...`, and
# nightly-settings.json allow-lists Bash(go:*)), so this grows on its
# own with every run.
#
# Called from a trap so it runs whether the stage succeeded, failed or
# timed out - the run that fills the disk is exactly the one that will
# not reach a tidy ending.
prune_build_caches() {
  local before after
  before="$(df -P "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"

  # go clean rather than rm -rf: the module cache is written read-only,
  # so rm fails on it and go knows how to drop its own caches.
  command -v go >/dev/null 2>&1 && {
    go clean -modcache >/dev/null 2>&1 || true
    go clean -cache    >/dev/null 2>&1 || true
  }
  command -v npm >/dev/null 2>&1 && npm cache clean --force >/dev/null 2>&1 || true

  after="$(df -P "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [ -n "$before" ] && [ -n "$after" ]; then
    echo "   caches pruned: $(( (after - before) / 1024 ))MB freed, $(( after / 1024 ))MB now free on $HOME"
  fi
}

# warn_if_home_tight
# Say so BEFORE the work starts, while a human can still act. The
# ENOSPC above surfaced only as a stage failure an hour into a run.
warn_if_home_tight() {
  local pct
  pct="$(df -P "$HOME" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
  [ -n "$pct" ] || return 0
  if [ "$pct" -ge 85 ]; then
    echo "WARNING: $HOME is ${pct}% full before this run; a transcript write that fails here reads as a BLOCKED ticket" >&2
  fi
}
