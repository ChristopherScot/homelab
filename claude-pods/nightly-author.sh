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

MODEL="${NIGHTLY_MODEL:-claude-fable-5-1}"
MAX_TICKETS="${NIGHTLY_MAX_TICKETS:-3}"
ROUNDS="${NIGHTLY_ROUNDS:-3}"
PER_TICKET_TIMEOUT="${NIGHTLY_TICKET_TIMEOUT:-3600}"
OWNER="${NIGHTLY_OWNER:-ChristopherScot}"
STATE_DIR="${NIGHTLY_STATE_DIR:-/workspace/.nightly}"
LOG="$STATE_DIR/author-$(date +%Y%m%d).log"

mkdir -p "$STATE_DIR"
exec > >(tee -a "$LOG") 2>&1
echo "=== nightly-author $(date -Is) model=$MODEL max=$MAX_TICKETS rounds=$ROUNDS ==="

GH_TOKEN="$(cat /run/secrets/git/token 2>/dev/null)"
export GH_TOKEN
if [ -z "$GH_TOKEN" ]; then echo "FATAL: no GitHub token"; exit 1; fi

# Clear the sentinel up front: pod 1 keys off it, and a stale one from
# yesterday would let it review a half-finished run as if it were complete.
rm -f "$STATE_DIR/author-done"

# Issues only — the REST API reports PRs under /issues too, and counting
# those is how "4 open tickets" turns into a job with nothing to do.
# Skip anything labelled blocked/wontfix: those need a human, and #25 is
# explicitly blocked on a credential only Chris can create.
collect_tickets() {
  local repo
  for repo in $(tr ',' ' ' < /run/secrets/repos/pod0); do
    if [[ "$repo" != "$OWNER"/* ]]; then
      continue
    fi
    gh api "repos/$repo/issues?state=open&per_page=100" \
      --jq ".[] | select(.pull_request == null)
             | select([.labels[].name] | any(. == \"blocked\" or . == \"wontfix\" or . == \"on-hold\") | not)
             | \"$repo#\(.number)\"" 2>/dev/null
  done
}

mapfile -t TICKETS < <(collect_tickets | head -n "$MAX_TICKETS")

if [ "${#TICKETS[@]}" -eq 0 ]; then
  echo "no actionable open issues; nothing to do"
  date -Is > "$STATE_DIR/author-done"
  exit 0
fi
echo "tickets: ${TICKETS[*]}"

for t in "${TICKETS[@]}"; do
  repo="${t%%#*}"
  num="${t##*#}"
  name="$(basename "$repo")"
  dir="/workspace/$name"
  [ -d "$dir" ] || { echo "SKIP $t: no clone at $dir"; continue; }

  echo "--- $t ($(date -Is))"
  git -C "$dir" fetch --quiet origin 2>/dev/null
  git -C "$dir" checkout --quiet "$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||' || echo main)" 2>/dev/null
  git -C "$dir" reset --hard --quiet origin/HEAD 2>/dev/null

  timeout "$PER_TICKET_TIMEOUT" claude -p --model "$MODEL" \
    --permission-mode acceptEdits \
    --add-dir "$dir" <<PROMPT
You are working in $dir on $repo issue #$num. Non-interactive: nobody can
answer questions, so make reasonable decisions and record them in the PR body.

1. Read the issue:  gh issue view $num --repo $repo
2. Decide if you can resolve it. Infrastructure and cluster work is in scope:
   this repo is GitOps, so prefer expressing the change as a manifest Argo
   will reconcile over an imperative kubectl command.
   Two things are still out of scope — write "SKIPPED: <reason>" and stop:
     - anything needing a credential or account only the owner can create
       (a GitHub App key, an OAuth login, a paid signup)
     - irreversible data loss: deleting a PV/PVC with reclaim Retain, dropping
       a database or table, force-pushing a shared branch, deleting a volume
       or snapshot. Propose it in the PR body instead and let a human run it.
   Reversible cluster changes are fine to make.
3. Otherwise branch: fix/issue-$num
4. Implement the smallest correct fix.
5. Add a regression test that FAILS without your fix. Verify this by reverting
   the fix, running the test to see it fail, then restoring the fix. A test
   that passes either way certifies nothing.
6. Run the project's own test command (make test if there is a Makefile,
   otherwise go test ./...). It must pass.
7. Then run $ROUNDS rounds of review. Each round, invoke these subagents on
   your diff: go-idioms-reviewer, 100-go-mistakes-reviewer,
   pragmatic-programmer-reviewer, philosophy-of-software-design-reviewer.
   (For a non-Go repo, use only the latter two.)
   Apply findings you agree with. Where you disagree, say why in the PR body
   rather than silently complying.
   Aim for DRY, orthogonal code with honest abstraction boundaries. Do NOT
   add layers, interfaces or indirection the ticket does not need — an
   over-abstracted fix is a worse outcome than a plain one. Simplify existing
   code only where it is in the path of this fix.
   Re-run the tests after every round.
8. Push the branch and open a PR with gh pr create. In the body: what changed,
   why, how the regression test was verified to fail without the fix, and any
   reviewer finding you declined with your reasoning.
9. Do not merge. Do not touch main.
PROMPT

  rc=$?
  [ $rc -eq 124 ] && echo "TIMEOUT after ${PER_TICKET_TIMEOUT}s on $t"
  echo "--- $t done rc=$rc"
done

date -Is > "$STATE_DIR/author-done"
echo "=== nightly-author complete $(date -Is) ==="
