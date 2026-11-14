#!/usr/bin/env bash
# Runs desloppify against projects/webapp and merges the result into the
# integration branch.
#
# The merge happens here, not in the agent: the agent's policy refuses
# `gh pr merge` outright, so the decision to land a change sits with this
# script and its checks rather than with the thing that wrote the change.
set -uo pipefail

# The image sets PATH so the venv comes first, but that applies to the
# container's main process; `kubectl exec` builds its own environment,
# and the CronJob's `env VAR=... script` does not restore it. A run
# invoked that way found no desloppify and exited at the PATH check,
# having logged everything up to it - which is how three runs produced
# a preflight log and a zero-byte report.
DESLOPPIFY_VENV="${DESLOPPIFY_VENV:-/opt/desloppify-venv}"
export PATH="$DESLOPPIFY_VENV/bin:$PATH"

REPO="${DESLOP_REPO:-schoolhouse-world/app}"
INTEGRATION_BRANCH="${DESLOP_INTEGRATION_BRANCH:-chris-agentic-looping}"
PROJECT_PATH="projects/webapp"
STATE_DIR="${DESLOP_STATE_DIR:-/workspace/.desloppify-state}"
WORK_ROOT="${DESLOP_WORK_ROOT:-/workspace}"
LOG="$STATE_DIR/desloppify-$(date +%Y%m%d).log"
HERE="${DESLOP_LIB_DIR:-/usr/local/share/desloppify-pod}"

# A faulted Longhorn volume answers every access with EIO rather than
# going away, so a run against one grinds instead of failing: the volume
# behind run 4 faulted at 01:35 and the agent kept issuing tool calls
# until 01:52, then sat for eleven hours. Single replica is deliberate
# here - the clone and node_modules are rebuildable - so the mount is
# checked rather than mirrored.
workspace_ok() {
  local probe="${WORK_ROOT}/.mount-probe.$$"
  [ -d "$WORK_ROOT" ] || return 1
  touch "$probe" 2>/dev/null || return 1
  rm -f "$probe" 2>/dev/null || return 1
  return 0
}

if ! workspace_ok; then
  echo "FATAL: $WORK_ROOT is not writable - the volume is detached or faulted."
  echo "       Check: kubectl get volumes.longhorn.io -n longhorn-system"
  exit 1
fi

# Without -e a failed mkdir is silent, and the redirection below then
# fails on a path that does not exist - with stdout already redirected,
# so the reason never appears anywhere.
if ! mkdir -p "$STATE_DIR"; then
  echo "FATAL: cannot create $STATE_DIR" >&2
  exit 1
fi

# Probe that the log path actually holds writes before redirecting into
# it. On a freshly woken pod the volume's first writes can flicker: the
# 2026-11-10 03:00 run got ENOENT opening this exact path sixteen lines
# after its mkdir succeeded, and died with the redirection as its only
# witness. Retrying beats dying - the flicker was gone minutes later.
_tries=0
until touch "$LOG" 2>/dev/null; do
  _tries=$((_tries + 1))
  if [ "$_tries" -ge 5 ]; then
    echo "FATAL: cannot write $LOG after $_tries attempts" >&2
    exit 1
  fi
  sleep 3
  mkdir -p "$STATE_DIR" 2>/dev/null || true
done

# Write to the file, then copy it to pid 1 on the way out, rather than
# teeing through a process substitution. `exec > >(tee ...)` leaves the
# substitution's stdin open with nothing to close it under `kubectl
# exec` without a TTY: the first scheduled run hung there and the
# CronJob killed it on activeDeadlineSeconds three hours later, having
# produced no log to explain itself.
#
# Alloy reads pid 1's stdout, so the copy is what reaches Loki. It runs
# on every exit path, including the FATALs below.
# The day's log accumulates across runs, so only this run's share is
# republished - otherwise a second run re-sends the first one's output.
_log_start=$(wc -l < "$LOG" 2>/dev/null || echo 0)
exec >> "$LOG" 2>&1
publish_log() {
  if [ -w /proc/1/fd/1 ]; then
    tail -n "+$((_log_start + 1))" "$LOG" > /proc/1/fd/1 2>/dev/null || true
  fi
}
trap publish_log EXIT

echo "=== nightly-desloppify $(date -Is) ==="

GH_TOKEN="$(cat /run/secrets/desloppify/token 2>/dev/null)"
export GH_TOKEN
if [ -z "$GH_TOKEN" ]; then echo "FATAL: no GitHub token"; exit 1; fi

# Work account first, personal held in reserve. A rate limit is per
# account and ends a run in under two seconds with no tool calls and no
# cost, so retrying on the other one is cheap and the night survives.
# use_claude_account also clears the API-key variables: either of them
# silently outranks the OAuth token and bills per token against the API
# account instead of the subscription.
# shellcheck source=../claude-pods/lib/claude-account.sh
. "${CLAUDE_ACCOUNT_LIB:-/usr/local/share/claude-pods/lib/claude-account.sh}"
preflight_credential || exit 1

# The token must not be able to reach main even if everything else fails.
# A fine-grained PAT without Administration cannot read protection; an
# admin token can. Refusing to start on an over-scoped token keeps the
# guarantee from quietly resting on the policy alone.
if gh api "repos/$REPO/branches/main/protection" >/dev/null 2>&1; then
  echo "FATAL: this token can read main's branch protection, so it is"
  echo "       over-scoped. Use a fine-grained PAT with Contents + Pull"
  echo "       requests write and NO Administration scope."
  exit 1
fi
echo "token scope: ok (cannot read main protection)"

name="$(basename "$REPO")"
dir="$WORK_ROOT/$name"
if [ ! -d "$dir/.git" ]; then
  echo "cloning $REPO"
  git clone --quiet "https://x-access-token:$GH_TOKEN@github.com/$REPO.git" "$dir" || exit 1
fi

# git's own refusal to push to a protected branch, independent of the
# agent's tool policy. A push the policy never sees - issued by the
# runner, or by a subprocess the agent spawned rather than a tool call -
# still goes through this, and a direct push to main needs no PR to do
# damage.
#
# Verified at install time: a hook that silently stops refusing is worse
# than none, because the layer above it was removed on its account.
install -m 755 "$HERE/git-hooks/pre-push" "$dir/.git/hooks/pre-push" || exit 1
if printf 'refs/heads/x 1 refs/heads/main 2\n' | "$dir/.git/hooks/pre-push" >/dev/null 2>&1; then
  echo "FATAL: the pre-push hook does not refuse main; refusing to run"
  exit 1
fi
echo "pre-push hook: installed, refuses main"

git -C "$dir" fetch --quiet origin || exit 1

# The integration branch is created once, from main, and never again:
# recreating it would discard everything merged into it so far.
if ! git -C "$dir" rev-parse --verify --quiet "origin/$INTEGRATION_BRANCH" >/dev/null; then
  echo "creating $INTEGRATION_BRANCH from origin/main"
  git -C "$dir" branch --quiet "$INTEGRATION_BRANCH" origin/main || exit 1
  git -C "$dir" push --quiet -u origin "$INTEGRATION_BRANCH" || exit 1
  git -C "$dir" fetch --quiet origin || exit 1
fi

# Stack on the last night's work with gh-stack. PRs are left open for
# review, so cutting each night from the integration branch would hand
# every run the same base and make the second one conflict with the first.
#
# This used to hand-roll it: find the newest open desloppify PR, then
# `git checkout -B new origin/that-branch`. That produced branches shaped
# like a stack that GitHub did not know were one, so none of the stack
# commands worked on them. In particular nothing retargeted the PRs above
# one that merged -- GitHub only retargets on merge, never on close, and
# a PR left based on a closed branch cannot be merged at all. homelab#64
# sat unmergeable for ten days for exactly that reason.
#
# --base keeps the trunk at the integration branch. main is never the
# trunk and never a base; the guard above refuses the run if this token
# can even see main's protection settings.
branch="desloppify/webapp-$(date +%Y%m%d-%H%M)"

# Resume an unfinished run before starting a new one.
#
# A run that dies between `gh stack add` and `gh stack submit` leaves a
# branch that is in the stack locally and has no PR on GitHub. Every
# lookup below goes through open PRs, so that branch is invisible to
# them: the run falls through to `gh stack init` and dies on "current
# branch is already part of a stack", and so does every run after it.
# Reachable by any interruption, not just the KEDA scale-to-0 at 06:30
# that exposed it on 2026-11-14 - a node eviction or an OOM does the
# same.
#
# `gh stack view --json` is the authority here precisely because it is
# local: it lists the stack's branches with `pr: null` on the ones never
# submitted. If the TOP of the stack is such a branch, this run adopts
# it rather than creating a sibling - the work already committed on it
# stays, and the agent continues on the queue it was working.
#
# Only the top, and only when it has no PR. A gap lower down is somebody
# mid-review, not an unfinished run, and claiming it would rewrite work
# a human is reading.
resume_branch=""
if stack_json=$( (cd "$dir" && GH_PAGER=cat gh stack view --json) 2>/dev/null ); then
  resume_branch=$(printf '%s' "$stack_json" | jq -r '
    .branches
    | last
    | select(.pr == null)
    | select(.name | startswith("desloppify/"))
    | .name // empty' 2>/dev/null)
fi
# `pr: null` is necessary but not sufficient. A branch whose PR was
# CLOSED rather than merged reads the same: gh stack re-resolves a
# tracked PR through a query scoped to states:[OPEN], gets nothing back,
# and drops the pr field. Adopting one of those would pile commits on
# work a human deliberately closed.
#
# A remote ref separates them without an API call. Never submitted means
# never pushed, so no origin/<branch> exists; a closed PR was pushed, so
# one does. Checked against the live fixture: the wedged branch has no
# origin ref and its submitted neighbour has one.
if [ -n "$resume_branch" ]    && git -C "$dir" rev-parse --verify -q "origin/$resume_branch" >/dev/null 2>&1; then
  echo "not resuming $resume_branch: it has a remote ref, so it was pushed"
  echo "  (a closed PR looks like an unsubmitted branch to gh stack; this one was submitted)"
  resume_branch=""
fi

if [ -n "$resume_branch" ]; then
  echo "resuming unfinished branch $resume_branch (in the stack, never pushed)"
  branch="$resume_branch"
fi

# checkout finds the stack CONTAINING a branch, and the trunk is not a
# member of its own stack - so look up the newest open desloppify PR and
# check that out instead. Any member reaches the whole stack.
prev_pr=$(gh pr list --repo "$REPO" --base "$INTEGRATION_BRANCH" --state open \
            --json number,headRefName,createdAt \
            --jq '[.[] | select(.headRefName | startswith("desloppify/"))]
                  | sort_by(.createdAt) | last | .number' 2>/dev/null)

# gh stack has no -C; it acts on the repo in the current directory, and
# this script otherwise never leaves its starting cwd (every git call
# passes -C "$dir"). So each of these runs in a subshell that cd's first.
if [ -n "$resume_branch" ]; then
  # The branch is already in the stack, so there is nothing to add - just
  # stand on it. No `gh stack sync` either: sync rebases the whole stack
  # and force-pushes it, and this branch has never been pushed, so there
  # is nothing to reconcile and a conflict here would strand the run
  # again in the state we are recovering from. The next `gh stack
  # submit` pushes it for the first time.
  if ! co_err=$( (cd "$dir" && git checkout "$branch") 2>&1 ); then
    echo "FATAL: cannot check out $branch to resume it"
    echo "$co_err" | head -5
    exit 1
  fi
  echo "work branch: $branch (resumed; picking up where the last run stopped)"
elif [ -n "$prev_pr" ] && [ "$prev_pr" != "null" ] \
   && (cd "$dir" && gh stack checkout "$prev_pr" >/dev/null 2>&1); then
  echo "found the existing stack via PR #$prev_pr"
  # Not a warning. sync is what rebases the stack onto its trunk, and
  # building tonight's branch on an unsynced stack is the state #64 sat
  # in for ten days. Keep the reason: a bare WARNING with no cause is
  # what the morning log used to say.
  if ! sync_err=$( (cd "$dir" && gh stack sync) 2>&1 ); then
    echo "FATAL: gh stack sync failed; refusing to stack on it"
    echo "$sync_err" | head -5
    exit 1
  fi
  # `checkout <pr>` lands on THAT PR's branch, and `add` only works from
  # the top of the stack - so adding straight after checkout fails with
  # "can only add branches to the top of the stack". Three nightly runs
  # died there (2026-11-11 through 13) because prev_pr is the BOTTOM of
  # the stack, which is the one position that is never the top.
  if ! top_err=$( (cd "$dir" && gh stack top) 2>&1 ); then
    echo "FATAL: gh stack top failed; cannot add to this stack"
    echo "$top_err" | head -5
    exit 1
  fi
  if ! add_err=$( (cd "$dir" && gh stack add "$branch") 2>&1 ); then
    echo "FATAL: gh stack add $branch failed"
    echo "$add_err" | head -5
    exit 1
  fi
  echo "work branch: $branch (added to the stack)"
else
  if ! init_err=$( (cd "$dir" && gh stack init "$branch" \
                      --base "$INTEGRATION_BRANCH") 2>&1 ); then
    echo "FATAL: gh stack init failed"
    echo "$init_err" | head -5
    exit 1
  fi
  echo "work branch: $branch (new stack on $INTEGRATION_BRANCH)"
fi
# Not on the resume path. `clean -qfd` deletes untracked files, and on a
# resumed branch those ARE the unfinished work - the fixture this was
# first tested against held four new source files (three tests and a new
# util) that this line would have destroyed before the agent started,
# which is the opposite of resuming. On a fresh branch it is still
# wanted: the clone is reused between runs and a previous run's debris
# must not look like this run's output.
if [ -z "$resume_branch" ]; then
  git -C "$dir" clean -qfd
else
  echo "keeping $(git -C "$dir" status --porcelain | grep -c '^??') untracked file(s) from the unfinished run"
fi

# desloppify keeps its queue in .desloppify. The clone is reset between
# runs, so the real directory lives on the PVC and is linked in - that is
# what makes the work incremental rather than restarting every night.
mkdir -p "$STATE_DIR/webapp"
rm -rf "$dir/.desloppify"
ln -s "$STATE_DIR/webapp" "$dir/.desloppify"

# `update-skill` writes .claude/skills/ relative to the working
# directory, so it has to run inside the clone - at build time it landed
# where nothing reads it. Without the overlay the CLI defaults to the
# codex runner, which is not installed here, and the review step
# completes as a dry run: twenty batch prompts written, no results, and
# the thirteen subjective dimensions left at zero.
(cd "$dir" && desloppify update-skill claude >/dev/null 2>&1) \
  || echo "WARNING: could not install the Claude review overlay"
if [ -f "$dir/.claude/skills/desloppify/SKILL.md" ]; then
  echo "claude overlay: installed"
else
  echo "WARNING: the Claude review overlay is missing - the subjective"
  echo "         dimensions will not be scored this run"
fi

if ! command -v desloppify >/dev/null 2>&1; then
  echo "FATAL: desloppify is not on PATH."
  echo "       PATH=$PATH"
  echo "       expected it at $DESLOPPIFY_VENV/bin/desloppify"
  exit 1
fi

report="$STATE_DIR/report-$(date +%Y%m%d-%H%M).json"

# One attempt on the account currently selected, writing its report.
# Agent directives fire at desloppify's own lifecycle transitions, which
# is a better place for these than the prompt: triage fires exactly when
# clustering happens, and execute fires as work starts, so the rule
# arrives at the moment it applies rather than as one wall of text read
# once at the beginning.
#
# Set here, not by hand on the pod, so they are version-controlled and a
# rebuilt pod does not silently lose them. Both are idempotent.
set_directives() (
  cd "$dir" || return 0
  desloppify directives set triage \
    "Each cluster should be one systemic change that stands on its own as a PR. Merge clusters that are really the same change; split one that is two. A cluster of hundreds of items is not reviewable - carve off a coherent subset and leave the rest queued." \
    >/dev/null 2>&1 || echo "WARNING: could not set the triage directive"
  desloppify directives set execute \
    "One cluster at a time. Finish it, commit it alone, then 'gh stack add' the next branch. One 'gh stack submit' at the end, never 'gh pr create'. Do not pass --open: these open as drafts for a human to read first. Same budget as always - the same work, in reviewable pieces." \
    >/dev/null 2>&1 || echo "WARNING: could not set the execute directive"
)
set_directives

run_once() {
  "${DESLOPPIFY_VENV:-/opt/desloppify-venv}/bin/python" "$HERE/run.py" \
    --repo "$REPO" --dir "$dir" --branch "$branch" \
    --integration-branch "$INTEGRATION_BRANCH" \
    --state-dir "$STATE_DIR/webapp" \
    --audit "$STATE_DIR/audit-$(date +%Y%m%d).jsonl" \
    --max-cost "${DESLOP_MAX_COST_USD:-50}" \
    --timeout "${DESLOP_TIMEOUT_S:-7200}" \
    > "$report"
}

# The signal is stop_reason, read with jq. Not a text match over the
# whole report: it embeds strings the agent wrote - a denial detail or a
# summary - and this repo has rate-limiting middleware, so "rate limit"
# appears there for reasons that have nothing to do with the account.
# Capturing stderr to look for it would also mix stderr into the JSON
# this script parses.
#
# One retry, because there are two accounts - a loop would be designing
# for a third that does not exist.
run_once
rc=$?
# Any exhaustion reason, not just api_error_429. run.py writes
# stop_reason from result.terminal_reason when the run is not is_error,
# so an account that runs out mid-run reports "limit_reached" or
# "quota_exceeded" - neither of which equals "api_error_429", so the
# equality test above silently skipped the retry and the night ended on
# one account with the other untouched. claude_rate_limited knows the
# full set and is the one place that list lives.
if [ "$rc" -ne 0 ] \
   && claude_rate_limited "$(jq -r '.stop_reason // ""' "$report" 2>/dev/null)"; then
  if use_claude_account personal; then
    echo "work account is rate limited; retrying on personal"
    cp "$report" "${report%.json}-work-attempt.json" 2>/dev/null || true
    run_once
    rc=$?
  else
    echo "work account is rate limited and no personal token is mounted" >&2
  fi
fi
echo "run rc=$rc report=$report"

# One logfmt line per run. The report reaches Loki either way, but as
# pretty-printed JSON it can only be matched as text; these fields are
# the ones worth graphing or alerting on. The scores come from the
# agent's own report, so they are absent on a run that never got far
# enough to read them.
jq -r '"desloppify_run outcome=\(.outcome // "BLOCKED") stop_reason=\(.stop_reason // "unknown") " +
       "pr=\(.pr_number // "none") cost_usd=\(.cost_usd // 0) turns=\(.turns // 0) " +
       "elapsed_s=\(.elapsed_s // 0) tools_allowed=\(.tools_allowed // 0) " +
       "tools_denied=\(.tools_denied // 0) findings=\(.output.findings_resolved | length? // 0) " +
       "score_before=\(.output.score_before // "na") score_after=\(.output.score_after // "na") " +
       "branch=\(.branch)"' "$report" 2>/dev/null

jq -r 'select(.stalled_after != null and .timed_out == true)
       | "desloppify_stall tool=\(.stalled_after.tool) idle_s=\(.stalled_after.idle_s) " +
         "detail=\(.stalled_after.detail | @json)"' "$report" 2>/dev/null

# The denial worth finding without reading a transcript: the agent went
# for a protected branch and the policy stopped it. Routine denials -
# chaining, unlisted binaries - fire constantly and would bury it.
jq -r '.denials[]? | select(.reason | test("protected branch|base is|protection"))
       | "desloppify_policy_stop detail=\(.detail | @json) reason=\(.reason | @json)"' \
   "$report" 2>/dev/null

# A run that ended badly may have ended because the filesystem went.
# Saying so beats reporting a timeout whose cause is a dead mount.
if ! workspace_ok; then
  echo "desloppify_mount_fault detail=\"$WORK_ROOT became unwritable during the run\""
fi

outcome=$(jq -r '.outcome // "BLOCKED"' "$report" 2>/dev/null)
pr=$(jq -r '.pr_number // empty' "$report" 2>/dev/null)
denied=$(jq -r '.tools_denied // 0' "$report" 2>/dev/null)
cost=$(jq -r '.cost_usd // "?"' "$report" 2>/dev/null)
stop=$(jq -r '.stop_reason // "unknown"' "$report" 2>/dev/null)
echo "outcome=$outcome stop_reason=$stop pr=${pr:-none} denied=$denied cost=$cost"

# Denials are expected - the policy refuses things routinely. A denial
# that names a protected branch is not routine, and is worth a human
# looking at the audit log.
jq -r '.denials[]? | select(.reason | test("protected branch|base is|protection"))
       | "  POLICY STOP: \(.detail) -- \(.reason)"' "$report" 2>/dev/null

if [ "$outcome" != "PROGRESS" ] || [ -z "$pr" ]; then
  echo "=== nightly-desloppify complete (no PR) $(date -Is) ==="
  exit $rc
fi

# The PR is left open. A change that landed on the integration branch
# without anyone reading it is the thing this pod is not for yet; the
# runner reports where to look instead.
# CI runs `yarn --immutable` before anything else, so a package.json
# edited without its lockfile fails every check at the install step.
# Run 5 removed prop-types - a peer dependency of react-katex - and all
# six checks died before linting. Saying so here beats reading six
# identical CI logs tomorrow.
if git -C "$dir" diff --name-only "origin/$INTEGRATION_BRANCH"...HEAD 2>/dev/null \
     | grep -q "package.json$"; then
  if (cd "$dir" && yarn install --immutable >/dev/null 2>&1); then
    echo "lockfile: consistent with package.json"
  else
    echo "desloppify_lockfile_drift pr=$pr detail=\"package.json changed but yarn.lock does not match; CI will fail at the install step\""
  fi
fi

# One PR per cluster, so name every one of them. pr_number alone sent
# the morning reader after the bottom of the stack while the rest of the
# night's work sat unmentioned. report.py derives pr_number from
# pr_numbers, so reaching here with a non-empty $pr means the list is
# non-empty too -- no fallback branch to get stale.
prs=$(jq -r '(.pr_numbers // [])[]' "$report" 2>/dev/null)
echo "open against $INTEGRATION_BRANCH and NOT merged:"
for n in $prs; do echo "  #$n  https://github.com/$REPO/pull/$n"; done
# Non-interactive submit implies --auto, which opens new PRs as drafts
# unless --open is passed -- and the policy refuses --open. Nothing
# merges from a draft; a reviewer marks each ready.
echo "  (drafts -- mark ready for review before merging)"

echo "=== nightly-desloppify complete $(date -Is) ==="
