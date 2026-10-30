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

# Shared preamble for the three nightly pods — see lib/nightly-common.sh.
# A fix there reaches all three.
NIGHTLY_LIB="${NIGHTLY_LIB:-/usr/local/share/claude-pods/lib/nightly-common.sh}"
# shellcheck source=lib/nightly-common.sh
source "$NIGHTLY_LIB" || { echo "FATAL: cannot source $NIGHTLY_LIB" >&2; exit 1; }

PER_PR_TIMEOUT="${NIGHTLY_PR_TIMEOUT:-1800}"
QUIET_MINUTES="${NIGHTLY_QUIET_MINUTES:-30}"
LOG="$STATE_DIR/merge-$(date +%Y%m%d).log"

log_to "$LOG"
echo "=== nightly-merge $(date -Is) model=$MODEL ==="

require_gh_token || exit 1
preflight_credential || exit 1

pick_model

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

    # Pod 2's integration testing gates the merge. Its tests are manual and
    # non-deterministic — they exercise the running software, so they cannot
    # live in CI — which means this is the only place that signal is
    # enforced. No verdict means not tested, never "nothing found": a pod 2
    # that timed out or crashed must not read as approval.
    labels=$(gh pr view "$pr" --repo "$repo" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null)
    case ",$labels," in
      *,tested-pass,*)    tested=PASS ;;
      *,tested-fail,*)    tested=FAIL ;;
      *,tested-blocked,*) tested=BLOCKED ;;
      *)                  tested="" ;;
    esac
    case "${tested:-NONE}" in
      PASS) : ;;
      FAIL)
        echo "NO-MERGE $repo#$pr: pod 2 integration testing FAILED"
        gh pr comment "$pr" --repo "$repo" --body "Nightly review (pod 1): not merged — pod 2's integration testing reported FAIL. See its comment above." >/dev/null 2>&1
        continue
        ;;
      *)
        echo "NO-MERGE $repo#$pr: no pod 2 verdict (${tested:-none}) — untested, not approved"
        gh pr comment "$pr" --repo "$repo" --body "Nightly review (pod 1): not merged — no integration-test verdict from pod 2 (reported: \`${tested:-none}\`). An untested change is not an approved one; leaving this for a human." >/dev/null 2>&1
        continue
        ;;
    esac

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
    # Heredoc written to a file first: nesting one inside $( ) trips bash's
    # parser on ordinary apostrophes in the prompt text.
    # Prompt lives in prompts/review.md so it can be edited without touching
    # this script. Exported so render_prompt's subprocess can see them.
    export dir repo pr
    render_prompt "$PROMPT_DIR/review.md" > "$STATE_DIR/prompt.txt"
    verdict=$(timeout "$PER_PR_TIMEOUT" claude -p --model "$MODEL" \
      --permission-mode acceptEdits --settings "$NIGHTLY_SETTINGS" --add-dir "$dir" < "$STATE_DIR/prompt.txt")
    rc=$?
    [ $rc -eq 124 ] && { echo "TIMEOUT on $repo#$pr"; continue; }

    echo "$verdict" | tail -20
    decision=$(printf '%s' "$verdict" | grep -oE '^VERDICT: (MERGE|NO-MERGE|RISKY)' | tail -1 | awk '{print $2}')

    case "$decision" in
      MERGE)
        # Merge method is per-repo and squash is disabled across all of
        # these, so asking for it unconditionally fails every merge
        # ("Squash merges are not allowed on this repository"). Pick a
        # method the repo actually permits.
        method="--merge"
        case "$(gh api "repos/$repo" --jq '"\(.allow_squash_merge) \(.allow_merge_commit)"' 2>/dev/null)" in
          "true "*) method="--squash" ;;
          *" true") method="--merge" ;;
          *)        method="--rebase" ;;
        esac
        if gh pr merge "$pr" --repo "$repo" $method --delete-branch >/dev/null 2>&1; then
          echo "MERGED $repo#$pr"
          # Recorded so the post-merge sweep below can revert it if main
          # goes red. Merging is only safe because undoing it is cheap.
          echo "$repo $pr" >> "$STATE_DIR/merged-$(date +%Y%m%d)"
          gh pr comment "$pr" --repo "$repo" --body "Nightly review (pod 1, independent panel): merged." >/dev/null 2>&1
        else
          echo "MERGE FAILED $repo#$pr"
        fi
        ;;
      RISKY)
        # Deliberately louder than NO-MERGE: the code may be correct, so
        # this is the case most likely to be waved through on a skim.
        echo "RISKY $repo#$pr — flagged for human decision"
        gh pr edit "$pr" --repo "$repo" --add-label "risky" >/dev/null 2>&1 \
          || gh label create risky --repo "$repo" --color B60205 \
               --description "Nightly review flagged this as too high blast-radius to auto-merge" >/dev/null 2>&1 \
          && gh pr edit "$pr" --repo "$repo" --add-label "risky" >/dev/null 2>&1
        gh pr comment "$pr" --repo "$repo" --body "## Nightly review (pod 1): RISKY — not merged

The change may well be correct; the concern is blast radius, not quality.
This one wants a human decision before it lands.

$(printf '%s' "$verdict" | tail -30)" >/dev/null 2>&1
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

# Post-merge sweep: a green PR check is not the same as a green main — the
# merge itself can break things (squashed semantic conflict, two PRs fine
# apart and broken together). Wait for main's CI, and revert anything that
# turned it red. Reverting fast beats agonising over the merge decision.
MERGED_FILE="$STATE_DIR/merged-$(date +%Y%m%d)"
if [ -s "$MERGED_FILE" ]; then
  echo "=== post-merge verification $(date -Is) ==="
  sort -u "$MERGED_FILE" | while read -r repo pr; do
    [ -z "$repo" ] && continue

    # Give main's run time to start and finish before judging it.
    status=""
    for _ in $(seq 1 40); do
      status=$(gh run list --repo "$repo" --branch main --limit 1 \
                 --json status,conclusion --jq '.[0] | "\(.status) \(.conclusion)"' 2>/dev/null)
      if [[ "$status" == completed\ * ]]; then
        break
      fi
      sleep 30
    done

    if [[ "$status" == "completed success" ]]; then
      echo "   ok      $repo#$pr (main green)"
    elif [[ "$status" == completed\ * ]]; then
      outcome="${status#completed }"
      echo "   BROKEN  $repo#$pr -> main is $outcome; reverting"
      if gh pr revert "$pr" --repo "$repo" --merge >/dev/null 2>&1; then
        echo "   REVERTED $repo#$pr"
        gh pr comment "$pr" --repo "$repo" --body \
          "Nightly: this merge turned main $outcome, so it has been reverted automatically. The branch work is preserved in the revert's parent commit." >/dev/null 2>&1
      else
        # A failed revert is worse than a failed merge: main stays broken
        # and nobody is watching until morning. Say so loudly in the log.
        echo "   REVERT FAILED $repo#$pr — main left broken, needs a human"
        gh pr comment "$pr" --repo "$repo" --body \
          "Nightly: this merge turned main $outcome and the automatic revert FAILED. main needs manual attention." >/dev/null 2>&1
      fi
    else
      echo "   UNKNOWN $repo#$pr (main CI still '$status' after 20m; not reverting)"
    fi
  done
fi

echo "=== nightly-merge complete $(date -Is) ==="
