#!/usr/bin/env bash
# Runs desloppify against projects/webapp and merges the result into the
# integration branch.
#
# The merge happens here, not in the agent: the agent's policy refuses
# `gh pr merge` outright, so the decision to land a change sits with this
# script and its checks rather than with the thing that wrote the change.
set -uo pipefail

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

CLAUDE_CODE_OAUTH_TOKEN="$(cat /run/secrets/claude/oauth-token 2>/dev/null)"
export CLAUDE_CODE_OAUTH_TOKEN
if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
  echo "FATAL: no Claude OAuth token"; exit 1
fi
# Either of these silently outranks the OAuth token and bills the API
# account per token.
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL

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

# Stack on the last night's work. PRs are left open for review, so
# cutting each night from the integration branch would hand every run
# the same base and make the second one conflict with the first.
base_ref="origin/$INTEGRATION_BRANCH"
base_pr=""
prev=$(gh pr list --repo "$REPO" --base "$INTEGRATION_BRANCH" --state open \
         --json number,headRefName,createdAt \
         --jq '[.[] | select(.headRefName | startswith("desloppify/"))]
               | sort_by(.createdAt) | last | "\(.number) \(.headRefName)"' 2>/dev/null)
if [ -n "$prev" ] && [ "$prev" != "null" ]; then
  base_pr="${prev%% *}"
  prev_branch="${prev##* }"
  if git -C "$dir" rev-parse --verify --quiet "origin/$prev_branch" >/dev/null; then
    base_ref="origin/$prev_branch"
    echo "stacking on PR #$base_pr ($prev_branch)"
  else
    echo "PR #$base_pr names a branch that is gone; basing on $INTEGRATION_BRANCH"
  fi
else
  echo "no open desloppify PR; basing on $INTEGRATION_BRANCH"
fi

branch="desloppify/webapp-$(date +%Y%m%d-%H%M)"
git -C "$dir" checkout --quiet -B "$branch" "$base_ref" || exit 1
git -C "$dir" clean -qfd
echo "work branch: $branch (from $base_ref)"

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
  echo "FATAL: desloppify is not on PATH; it is baked into the image"
  exit 1
fi

report="$STATE_DIR/report-$(date +%Y%m%d-%H%M).json"
"${DESLOPPIFY_VENV:-/opt/desloppify-venv}/bin/python" "$HERE/run.py" \
  --repo "$REPO" --dir "$dir" --branch "$branch" \
  --integration-branch "$INTEGRATION_BRANCH" \
  --state-dir "$STATE_DIR/webapp" \
  --audit "$STATE_DIR/audit-$(date +%Y%m%d).jsonl" \
  --max-cost "${DESLOP_MAX_COST_USD:-50}" \
  --timeout "${DESLOP_TIMEOUT_S:-7200}" \
  > "$report"
rc=$?
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

echo "PR #$pr is open against $INTEGRATION_BRANCH and was NOT merged"
echo "  https://github.com/$REPO/pull/$pr"

echo "=== nightly-desloppify complete $(date -Is) ==="
