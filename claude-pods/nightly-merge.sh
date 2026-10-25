#!/usr/bin/env bash
# Pod 1's 04:00 job: an independent verdict on the PRs pod 0 opened at 00:00.
#
# The point is that this panel has NOT seen pod 0's reasoning. It gets a fresh
# clone and the diff, nothing else — no author transcript, no earlier review
# history. Self-review anchors on its own argument; a cold read does not.
#
# Merge requires BOTH a unanimous panel pass AND green CI. CI is the only
# signal in this system that no agent produced, and two panels of the same
# four agents reading the same diff are correlated, not independent.
set -uo pipefail

MODEL="${NIGHTLY_MODEL:-claude-fable-5-1}"
PER_PR_TIMEOUT="${NIGHTLY_PR_TIMEOUT:-1800}"
OWNER="${NIGHTLY_OWNER:-ChristopherScot}"
STATE_DIR="${NIGHTLY_STATE_DIR:-/workspace/.nightly}"
QUIET_MINUTES="${NIGHTLY_QUIET_MINUTES:-30}"
LOG="$STATE_DIR/merge-$(date +%Y%m%d).log"

mkdir -p "$STATE_DIR"
exec > >(tee -a "$LOG") 2>&1
echo "=== nightly-merge $(date -Is) model=$MODEL ==="

GH_TOKEN="$(cat /run/secrets/git/token 2>/dev/null)"
export GH_TOKEN
if [ -z "$GH_TOKEN" ]; then echo "FATAL: no GitHub token"; exit 1; fi

now=$(date +%s)

for repo in $(tr ',' ' ' < /run/secrets/repos/pod1); do
  if [[ "$repo" != "$OWNER"/* ]]; then
    continue
  fi

  mapfile -t PRS < <(gh pr list --repo "$repo" --state open --json number,headRefName,updatedAt \
    --jq '.[] | select(.headRefName | startswith("fix/issue-")) | "\(.number) \(.updatedAt)"' 2>/dev/null)
  [ "${#PRS[@]}" -eq 0 ] && continue

  for entry in "${PRS[@]}"; do
    pr="${entry%% *}"
    updated="${entry##* }"

    # Don't judge a branch that is still moving: if pod 0 overran, the diff
    # under review may not be the diff that ends up on the branch.
    upd=$(date -d "$updated" +%s 2>/dev/null || echo 0)
    if [ "$upd" -gt 0 ] && [ $(( (now - upd) / 60 )) -lt "$QUIET_MINUTES" ]; then
      echo "SKIP $repo#$pr: updated $(( (now - upd) / 60 ))m ago, still settling"
      continue
    fi

    # CI must be green on its own merits before any agent opinion counts.
    checks=$(gh pr checks "$pr" --repo "$repo" 2>&1)
    if echo "$checks" | grep -qiE '\b(fail|failure|error)\b'; then
      echo "NO-MERGE $repo#$pr: CI not green"
      gh pr comment "$pr" --repo "$repo" --body "Nightly review (pod 1): not merged — CI is not green." >/dev/null 2>&1
      continue
    fi
    if echo "$checks" | grep -qiE '\b(pending|in_progress|queued)\b'; then
      echo "SKIP $repo#$pr: CI still running"
      continue
    fi

    name="$(basename "$repo")"
    dir="/workspace/$name"
    [ -d "$dir" ] || { echo "SKIP $repo#$pr: no clone"; continue; }
    git -C "$dir" fetch --quiet origin 2>/dev/null

    echo "--- reviewing $repo#$pr ($(date -Is))"
    verdict=$(timeout "$PER_PR_TIMEOUT" claude -p --model "$MODEL" \
      --permission-mode acceptEdits --add-dir "$dir" <<PROMPT
You are reviewing $repo pull request #$pr in $dir. You have NOT seen how this
change was written and you must not go looking for the author's reasoning —
judge the diff on its own merits.

1. gh pr checkout $pr --repo $repo
2. Read the full diff against the base branch, and the issue it closes.
3. Run the project's own test command (make test, else go test ./...).
4. Convince yourself the regression test actually fails without the fix:
   revert the non-test changes, run the test, confirm it fails, restore.
   If it passes without the fix, the test proves nothing — that is a reject.
5. Invoke each of these subagents on the diff: go-idioms-reviewer,
   100-go-mistakes-reviewer, pragmatic-programmer-reviewer,
   philosophy-of-software-design-reviewer. (Non-Go repo: the latter two.)
6. Reject over-engineering as firmly as under-engineering: needless
   interfaces, premature abstraction, indirection the ticket did not call
   for. DRY and orthogonal, not clever.

Then print exactly one final line, nothing after it:
  VERDICT: MERGE     - correct, tested, idiomatic, no reviewer objections
  VERDICT: NO-MERGE  - any reviewer objection, failing//ineffective test, or doubt
Above that line, give a short rationale.
PROMPT
)
    rc=$?
    [ $rc -eq 124 ] && { echo "TIMEOUT on $repo#$pr"; continue; }

    echo "$verdict" | tail -20
    decision=$(printf '%s' "$verdict" | grep -oE '^VERDICT: (MERGE|NO-MERGE)' | tail -1 | awk '{print $2}')

    case "$decision" in
      MERGE)
        if gh pr merge "$pr" --repo "$repo" --squash --delete-branch >/dev/null 2>&1; then
          echo "MERGED $repo#$pr"
          gh pr comment "$pr" --repo "$repo" --body "Nightly review (pod 1, independent panel): merged." >/dev/null 2>&1
        else
          echo "MERGE FAILED $repo#$pr"
        fi
        ;;
      NO-MERGE)
        echo "HELD $repo#$pr"
        gh pr comment "$pr" --repo "$repo" --body "Nightly review (pod 1, independent panel): held for human review.

$(printf '%s' "$verdict" | tail -30)" >/dev/null 2>&1
        ;;
      *)
        # No parseable verdict means the run broke, not that the PR is good.
        echo "HELD $repo#$pr: no verdict parsed"
        ;;
    esac
  done
done

echo "=== nightly-merge complete $(date -Is) ==="
