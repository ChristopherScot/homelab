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

mkdir -p "$STATE_DIR"
if [ -w /proc/1/fd/1 ]; then
  exec > >(tee -a "$LOG" > /proc/1/fd/1) 2>&1
else
  exec > >(tee -a "$LOG") 2>&1
fi
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

branch="desloppify/webapp-$(date +%Y%m%d-%H%M)"
git -C "$dir" checkout --quiet -B "$branch" "origin/$INTEGRATION_BRANCH" || exit 1
git -C "$dir" clean -qfd
echo "work branch: $branch (from origin/$INTEGRATION_BRANCH)"

# desloppify keeps its queue in .desloppify. The clone is reset between
# runs, so the real directory lives on the PVC and is linked in - that is
# what makes the work incremental rather than restarting every night.
mkdir -p "$STATE_DIR/webapp"
rm -rf "$dir/.desloppify"
ln -s "$STATE_DIR/webapp" "$dir/.desloppify"

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
  > "$report"
rc=$?
echo "run rc=$rc report=$report"

# One line per run, as logfmt, so Loki can filter on the fields rather
# than matching inside a pretty-printed JSON blob. The full report stays
# on the PVC for anything this does not carry.
jq -r '"desloppify_run outcome=\(.outcome // "BLOCKED") pr=\(.pr_number // "none") " +
       "cost_usd=\(.cost_usd // 0) turns=\(.turns // 0) elapsed_s=\(.elapsed_s // 0) " +
       "tools_allowed=\(.tools_allowed // 0) tools_denied=\(.tools_denied // 0) " +
       "findings=\(.output.findings_resolved | length // 0) repo=\(.repo) branch=\(.branch)"' \
   "$report" 2>/dev/null

# A denial naming a protected branch is the one worth alerting on: it
# means the agent tried for main and the policy stopped it.
jq -r '.denials[]? | select(.reason | test("protected branch|base is|protection"))
       | "desloppify_policy_stop detail=\(.detail | @json) reason=\(.reason | @json)"' \
   "$report" 2>/dev/null

outcome=$(jq -r '.outcome // "BLOCKED"' "$report" 2>/dev/null)
pr=$(jq -r '.pr_number // empty' "$report" 2>/dev/null)
denied=$(jq -r '.tools_denied // 0' "$report" 2>/dev/null)
cost=$(jq -r '.cost_usd // "?"' "$report" 2>/dev/null)
echo "outcome=$outcome pr=${pr:-none} denied=$denied cost=$cost"

# Denials are expected - the policy refuses things routinely. A denial
# that names a protected branch is not routine, and is worth a human
# looking at the audit log.
jq -r '.denials[]? | select(.reason | test("protected branch|base is|protection"))
       | "  POLICY STOP: \(.detail) -- \(.reason)"' "$report" 2>/dev/null

if [ "$outcome" != "PROGRESS" ] || [ -z "$pr" ]; then
  echo "=== nightly-desloppify complete (no PR) $(date -Is) ==="
  exit $rc
fi

# Verify the PR before merging it. The agent cannot merge, so these
# checks are the only gate, and a PR that targets anything but the
# integration branch must never land.
base=$(gh pr view "$pr" --repo "$REPO" --json baseRefName --jq .baseRefName 2>/dev/null)
if [ "$base" != "$INTEGRATION_BRANCH" ]; then
  echo "REFUSING to merge PR #$pr: base is '$base', expected '$INTEGRATION_BRANCH'"
  gh pr comment "$pr" --repo "$REPO" \
    --body "Not merged: base is \`$base\`, which is not the integration branch." >/dev/null 2>&1
  exit 1
fi

files=$(gh pr view "$pr" --repo "$REPO" --json files --jq '[.files[].path] | length' 2>/dev/null)
outside=$(gh pr view "$pr" --repo "$REPO" --json files \
  --jq "[.files[].path | select(startswith(\"$PROJECT_PATH/\") | not)] | length" 2>/dev/null)
if [ "${outside:-0}" -gt 0 ]; then
  echo "REFUSING to merge PR #$pr: $outside file(s) outside $PROJECT_PATH"
  gh pr comment "$pr" --repo "$REPO" \
    --body "Not merged: $outside file(s) fall outside \`$PROJECT_PATH\`." >/dev/null 2>&1
  exit 1
fi
echo "PR #$pr: base=$base files=$files, all within $PROJECT_PATH"

sha=$(gh pr view "$pr" --repo "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null)
if gh pr merge "$pr" --repo "$REPO" --squash --delete-branch \
     --match-head-commit "$sha" >/dev/null 2>&1; then
  echo "merged PR #$pr into $INTEGRATION_BRANCH at $sha"
else
  echo "merge of PR #$pr failed (left open for review)"
fi

echo "=== nightly-desloppify complete $(date -Is) ==="
