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

# Tool permissions remain a local enforcement boundary. A prompt cannot
# expand the worker's configured permissions.
NIGHTLY_SETTINGS="${NIGHTLY_SETTINGS:-/usr/local/share/claude-pods/prompts/nightly-settings.json}"

# Fetch once and archive exact payload/rendered bytes before starting work.
# A command's audit directory is never reused for a second execution.
load_dispatch_command() {
  local stage="$1" code
  COMMAND_DIR="$STATE_DIR/commands/$DISPATCH_COMMAND"
  mkdir -p "$STATE_DIR/commands" || return 1
  (umask 077; mkdir "$COMMAND_DIR") || return 1
  code=$(curl --silent --show-error --connect-timeout 10 --max-time 40 --max-filesize 262144 \
    -H "Authorization: Bearer $DISPATCH_API_KEY" -H 'Content-Type: application/json' \
    --data-binary "$(jq -cn --arg task "$ONLY_TASK" --arg command "$DISPATCH_COMMAND" '{version:1,task:$task,command:$command}')" \
    --output "$COMMAND_DIR/command.json" --write-out '%{http_code}' \
    "${KANEO_DISPATCH_URL:-http://kaneo-dispatcher.claude-pods.svc.cluster.local:8080}/worker-command") || return 1
  [ "$code" = 200 ] || { echo "dispatcher command unavailable (HTTP $code)" >&2; return 1; }
  node "$(dirname "${BASH_SOURCE[0]}")/command-prompt.js" \
    "$COMMAND_DIR/command.json" "$ONLY_TASK" "$ONLY_REPO" "$DISPATCH_COMMAND" "$stage" \
    "/workspace/$(basename "$ONLY_REPO")" || return 1
  COMMAND_PAYLOAD="$COMMAND_DIR/payload.json"
  COMMAND_PROMPT="$COMMAND_DIR/prompt.txt"
  COMMAND_DIGEST=$(jq -r .prompt.digest "$COMMAND_DIR/command.json")
  COMMAND_MODE=$(jq -r .mode "$COMMAND_PAYLOAD")
  COMMAND_TIMEOUT=$(jq -r .timeoutSeconds "$COMMAND_PAYLOAD")
  COMMAND_BRANCH=$(jq -r .branch "$COMMAND_PAYLOAD")
  export COMMAND_DIR COMMAND_PAYLOAD COMMAND_PROMPT
}

# Check frozen remote observations, never silently choose another mode/head.
# Local changes are preserved by holding rather than resetting over them.
prepare_command_checkout() {
  local dir="$1" base base_sha branch_sha expected actual remote_refs
  base=$(jq -r .base "$COMMAND_PAYLOAD")
  base_sha=$(jq -r .baseSHA "$COMMAND_PAYLOAD")
  branch_sha=$(jq -r .branchSHA "$COMMAND_PAYLOAD")
  actual=$(git -C "$dir" status --porcelain) || return 1
  [ -z "$actual" ] || { echo 'local edits preserved; checkout held' >&2; return 1; }
  # Retain remote-tracking publication evidence even when preparation fails.
  # A squash-merged task branch can disappear without its SHA reaching main.
  for expected in HEAD "$COMMAND_BRANCH"; do
    if git -C "$dir" rev-parse --verify "$expected" >/dev/null 2>&1; then
      actual=$(git -C "$dir" rev-list "$expected" --not --remotes=origin) || return 1
      [ -z "$actual" ] || { echo 'unpushed commits preserved; checkout held' >&2; return 1; }
    fi
  done
  git -C "$dir" fetch --quiet --no-prune origin || return 1
  remote_refs=$(git -C "$dir" ls-remote origin "refs/heads/$base" "refs/heads/$COMMAND_BRANCH") || return 1
  actual=$(printf '%s\n' "$remote_refs" | awk -v ref="refs/heads/$base" '$2 == ref {print $1}')
  [ "$actual" = "$base_sha" ] || {
    echo 'command base changed; waiting for a new command' >&2; return 1;
  }
  actual=$(printf '%s\n' "$remote_refs" | awk -v ref="refs/heads/$COMMAND_BRANCH" '$2 == ref {print $1}')
  [ "$actual" = "$branch_sha" ] || { echo 'command branch changed; waiting for a new command' >&2; return 1; }
  case "$COMMAND_MODE" in
    author) git -C "$dir" checkout --quiet -B "$COMMAND_BRANCH" "$base_sha" ;;
    resume|rework|test|review) git -C "$dir" checkout --quiet -B "$COMMAND_BRANCH" "$branch_sha" ;;
    *) return 1 ;;
  esac
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
# TWO readers probe it with `flock -n <path> true`: the dispatcher before
# launching a stage (podIsBusy in github.com/ChristopherScot/kaneo-dispatcher, which uses
# the same expression as below, override included, and has a test
# holding the two together) and the session-sleep cron before scaling
# the pods to 0, which hardcodes /tmp/nightly.lock. The stakes differ: a
# dispatcher misread starts a duplicate agent; a reaper misread
# TERMINATES a live run as "idle". So the NIGHTLY_LOCK override below
# must never be set in a session pod — a run holding a different path is
# invisible to the reaper.
# The dispatcher gives each launch a private acknowledgment path. A timeout
# removes its directory; failing to acknowledge must stop this worker too.
acknowledge_launch() {
  [ -n "${NIGHTLY_LAUNCH_ACK:-}" ] || return 0
  printf '%s\n' "$1" > "${NIGHTLY_LAUNCH_ACK}.tmp" &&
    mv "${NIGHTLY_LAUNCH_ACK}.tmp" "$NIGHTLY_LAUNCH_ACK"
}

take_pod_lock() {
  exec 9>"${NIGHTLY_LOCK:-/tmp/nightly.lock}"
  if ! flock -n 9; then
    acknowledge_launch busy || true
    echo "another nightly stage is already running in this pod; exiting" >&2
    return 1
  fi
  acknowledge_launch accepted
}

# --- Dispatcher commands --------------------------------------------------
# Kaneo reads, policy selection and board writes belong to the dispatcher.
# Helpers retain their historical names for the stage scripts, but report
# command-scoped events rather than calling the Kaneo API.
kaneo_branch_for_task() {
  [ "$1" = "$ONLY_TASK" ] || return 1
  printf '%s' "$COMMAND_BRANCH"
}

require_dispatch_key() {
  DISPATCH_API_KEY="$(cat /run/secrets/kaneo/api-key 2>/dev/null)"
  # This key authenticates dispatcher RPCs; agents need no Kaneo environment.
  unset KANEO_API_KEY KANEO_API_URL
  export -n DISPATCH_API_KEY
  [ -n "$DISPATCH_API_KEY" ] || { echo 'FATAL: dispatcher API credential missing' >&2; return 1; }
}

# A stage cannot discover or select work. The command ID is created and
# persisted by the dispatcher, and every report must name that exact command.
require_dispatch_command() {
  ONLY_TASK="${1:-}"
  ONLY_REPO="${2:-}"
  DISPATCH_COMMAND="${3:-}"
  [ -n "$ONLY_TASK" ] && [ -n "$ONLY_REPO" ] && [ -n "$DISPATCH_COMMAND" ] || {
    echo 'FATAL: dispatcher task, repository and command ID are required' >&2
    return 1
  }
  [[ "$DISPATCH_COMMAND" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || return 1
  export ONLY_TASK ONLY_REPO DISPATCH_COMMAND
}

# Require the synchronous v1 acknowledgment. Older dispatchers answer unknown
# POST paths with 202, which is NOT acceptance. Never retry an uncertain write.
dispatcher_report() {
  local event="$1" extra="${2:-}" payload reply code body
  [ -n "${DISPATCH_COMMAND:-}" ] && [ -n "${ONLY_TASK:-}" ] || return 1
  [ -n "$extra" ] || extra='{}'
  payload=$(jq -cn --arg task "$ONLY_TASK" --arg command "$DISPATCH_COMMAND" \
    --arg event "$event" --argjson extra "$extra" \
    '$extra + {task:$task,command:$command,event:$event}') || return 1
  reply=$(curl --silent --show-error --connect-timeout 10 --max-time 95 \
    -H "Authorization: Bearer $DISPATCH_API_KEY" -H 'Content-Type: application/json' \
    --data-binary "$payload" --write-out '\n%{http_code}' \
    "${KANEO_DISPATCH_URL:-http://kaneo-dispatcher.claude-pods.svc.cluster.local:8080}/worker-events") || return 1
  code="${reply##*$'\n'}"
  body="${reply%$'\n'*}"
  if [ "$code" != 200 ] || ! printf '%s' "$body" | jq -e \
    --arg task "$ONLY_TASK" --arg command "$DISPATCH_COMMAND" --arg event "$event" \
    '.version == 1 and .accepted == true and .task == $task and .command == $command and .event == $event' >/dev/null; then
    echo "dispatcher rejected $event for $ONLY_TASK (HTTP $code)" >&2
    return 1
  fi
}

kaneo_work_started() {
  [ "$1" = "${ONLY_TASK:-}" ] || return 1
  DISPATCH_STAGE="${2#stage-}"
  export DISPATCH_STAGE
  dispatcher_report "$DISPATCH_STAGE-started" "$(jq -cn --arg digest "$COMMAND_DIGEST" '{promptDigest:$digest}')"
}

kaneo_outcome() {
  [ "$1" = "$ONLY_TASK" ] || return 1
  dispatcher_report "$DISPATCH_STAGE-$2"
}

kaneo_note() {
  [ "$1" = "$ONLY_TASK" ] || return 1
  dispatcher_report note "$(jq -cn --arg message "$2" '{message:$message}')"
}

kaneo_link_pr() {
  [ "$1" = "$ONLY_TASK" ] || return 1
  dispatcher_report link "$(jq -cn --arg url "$2" --arg title "${3:-pull request}" '{url:$url,title:$title}')"
}

kaneo_mention() { kaneo_note "$1" "@$2 $3"; }

# Exact assigned-task PR selection, shared by author recovery and both review
# stages. Forks reusing a branch name and old merged links cannot select work.
command_pr() {
  gh pr list --repo "$ONLY_REPO" --state open \
    --head "$(kaneo_branch_for_task "$ONLY_TASK")" --limit 100 \
    --json number,url,headRefName,headRepositoryOwner,headRepository,updatedAt,headRefOid | \
    jq -c --arg repo "$ONLY_REPO" --arg branch "$(kaneo_branch_for_task "$ONLY_TASK")" \
      '[.[] | select(.headRefName == $branch and ((.headRepositoryOwner.login + "/" + .headRepository.name | ascii_downcase) == ($repo | ascii_downcase)))] | sort_by(.number) | last // empty'
}

# The headline the dispatcher counts in its task-context snapshot.
# A literal shared by a writer and a reader in different files is a
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
  kaneo_note "$task" "$KANEO_REWORK_HEADLINE: ${why:0:9000}" || {
    echo "   dispatcher: requeue held because its rework receipt failed" >&2
    return 1
  }
  kaneo_outcome "$task" failed
}

# Confirm the PR belongs to the repository and branch frozen in this command.
kaneo_task_for_pr() {
  local repo="$1" pr="$2" head
  head="$(gh pr view "$pr" --repo "$repo" --json headRefName --jq .headRefName 2>/dev/null)"
  [ "$repo" = "$ONLY_REPO" ] && [ "$head" = "$COMMAND_BRANCH" ] || return 1
  printf '%s' "$ONLY_TASK"
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
    echo "   kaneo: no card for $repo#$pr (not the assigned command branch); not requeued" >&2
    return 1
  }
  summary="$(printf '%s' "$verdict" | grep -v '^VERDICT:' | sed '/^[[:space:]]*$/d' | head -6)"
  kaneo_requeue "$task" "the review panel declined PR #$pr

$summary"
}

# The one disk-pressure threshold, shared by the warning and the prune:
# the point where this home is tight enough to act on. Overridable so
# tuning it is one env var, not two edits.
HOME_TIGHT_PCT="${HOME_TIGHT_PCT:-85}"

# agent_is_running
# True if a Claude agent launched by THIS stage is still alive.
#
# Two things make this fiddly, and both were found by running it in the
# pod rather than reasoning about it:
#
#   1. It must not ask "do I have a child". The stage shell always has
#      one: log_to's `tee` is forked by `exec > >(tee ...)` and lives
#      for the whole run by design, so a child-counting guard never
#      lets the prune run at all.
#   2. It must not ask "is any process named claude alive". An attached
#      Remote Control session (`claude --remote-control ...`, under
#      tmux) is one, and it is nobody's stage agent - blocking the
#      prune whenever a human is attached is the opposite of useful.
#
# So: a process named claude whose ancestry leads back to this shell.
# Walking ancestry rather than checking a direct child because bash may
# interpose a subshell for `out=$(timeout ... claude -p ...)`, and the
# three stages each invoke the agent in a different shape.
#
# Reads /proc rather than pgrep/ps: the pod image is
# node:22-trixie-slim with no procps, so both are missing there. A
# guard built on them passes on a developer's Mac and does nothing in
# the pod. Falls back to pgrep where /proc is absent (macOS), so the
# same code stays testable off-cluster.
agent_is_running() {
  local p comm stat state anc hops
  if [ -d /proc ]; then
    for p in /proc/[0-9]*; do
      [ -r "$p/comm" ] || continue
      read -r comm < "$p/comm" 2>/dev/null || continue
      # comm, verified empirically rather than assumed: the shipped
      # claude is a Bun-compiled binary named claude.exe that renames
      # its own main thread to `claude` via prctl, and `timeout` execs
      # it directly without interposing. Checked against the running
      # agent in the pod. This is an implementation detail, not a
      # contract - if a release ever drops the rename, comm becomes
      # claude.exe, this returns false and the prune runs mid-agent, so
      # claude.exe is matched too rather than relying on the rename.
      case "$comm" in claude|claude.exe) ;; *) continue ;; esac
      stat="$(sed -e 's/.*) //' "$p/stat" 2>/dev/null)" || continue
      state="$(printf '%s' "$stat" | awk '{print $1}')"
      # Dead but unreaped is not still working.
      [ "$state" = Z ] && continue
      # Climb to pid 1; a bounded walk, so a cycle cannot hang a trap.
      anc="$(printf '%s' "$stat" | awk '{print $2}')"
      hops=0
      while [ -n "$anc" ] && [ "$anc" != 0 ] && [ "$hops" -lt 32 ]; do
        [ "$anc" = "$$" ] && return 0
        stat="$(sed -e 's/.*) //' "/proc/$anc/stat" 2>/dev/null)" || break
        anc="$(printf '%s' "$stat" | awk '{print $2}')"
        hops=$((hops + 1))
      done
    done
    return 1
  fi
  # macOS only, where there is no /proc. Same question as above - a
  # claude under this shell - asked with pgrep's own ancestry filter so
  # the tee and an unrelated Remote Control session are both excluded.
  command -v pgrep >/dev/null 2>&1 || return 1
  local p
  for p in $(pgrep -x claude 2>/dev/null); do
    pgrep -P "$$" >/dev/null 2>&1 || break
    # Climb this pid's ancestry via ps, which macOS does have.
    local anc=$p hops=0
    while [ -n "$anc" ] && [ "$anc" != 1 ] && [ "$hops" -lt 32 ]; do
      [ "$anc" = "$$" ] && return 0
      anc="$(ps -o ppid= -p "$anc" 2>/dev/null | tr -d ' ')" || break
      hops=$((hops + 1))
    done
  done
  return 1
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
#
# Pruning only under pressure, not on every exit. ROUTES pins each stage
# to its own pod and its own home PVC, so there is no cross-stage cache
# to protect - but pod0 runs the author stage again tomorrow, and today's
# caches are what keeps that run inside PER_TICKET_TIMEOUT. Dropping them
# unconditionally buys headroom nobody needed and trades a
# BLOCKED-on-full-disk for a BLOCKED-on-timeout, which is the same
# failure wearing a different hat.
prune_build_caches() {
  local before after pct

  # The EXIT trap fires as soon as bash stops waiting on its child, which
  # on SIGTERM is BEFORE a TERM-ignoring child has died. Pruning there
  # would delete the module cache mid `go test`, and the agent would
  # report missing packages - an environmental fault wearing a ticket's
  # clothes, which is the whole thing this function exists to prevent.
  #
  # Not `jobs`: the agent runs in the FOREGROUND inside a command
  # substitution (out=$(timeout ... claude -p ...)), and `jobs` lists
  # only background jobs, so it is empty in exactly the case this guard
  # is for.
  if agent_is_running; then
    echo "   caches NOT pruned: the agent is still running" >&2
    return 0
  fi

  pct="$(df -P "$HOME" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
  if [ -n "$pct" ] && [ "$pct" -lt "$HOME_TIGHT_PCT" ]; then
    return 0
  fi

  before="$(df -P "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"

  # go clean rather than rm -rf: the module cache is written read-only,
  # so rm fails on it and go knows how to drop its own caches.
  command -v go >/dev/null 2>&1 && {
    go clean -modcache >/dev/null 2>&1 || true
    go clean -cache    >/dev/null 2>&1 || true
  }
  if command -v npm >/dev/null 2>&1; then
    npm cache clean --force >/dev/null 2>&1 || true
  fi

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
  if [ "$pct" -ge "$HOME_TIGHT_PCT" ]; then
    echo "WARNING: $HOME is ${pct}% full before this run; a transcript write that fails here reads as a BLOCKED ticket" >&2
  fi
}
