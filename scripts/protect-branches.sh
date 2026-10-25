#!/usr/bin/env bash
# Require green CI before anything can merge to the default branch.
#
# Written for the nightly pipeline: pod 1 merges unattended, and a prompt
# telling it to check CI is not a guarantee. This makes the rule GitHub's,
# not the agent's.
#
# enforce_admins=true matters here. The bot pushes as ChristopherScot, who
# owns these repos, so with admin bypass left on the protection would not
# actually constrain it — which would be protection in name only.
#
# Required checks are per-repo: homelabctl reports "test"/"release",
# pokemon reports "build", and a wrong context name either blocks every
# merge forever or silently requires nothing. So each repo's contexts are
# discovered from what its CI actually reported on the latest commit.
#
#   ./scripts/protect-branches.sh            # show what would change
#   ./scripts/protect-branches.sh --apply    # apply it
set -euo pipefail

OWNER="${OWNER:-ChristopherScot}"
APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true

command -v gh >/dev/null || { echo "gh not found"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh not authenticated"; exit 1; }

echo "=== branch protection for $OWNER (apply=$APPLY) ==="

gh api "users/$OWNER/repos?per_page=100" \
  --jq '.[] | select(.archived == false) | select(.fork == false) | "\(.name) \(.default_branch)"' \
| while read -r repo branch; do
    # Discover the checks this repo's CI actually reports. A repo with no
    # CI gets protection without required contexts — still blocks direct
    # pushes and force-pushes, just has no status gate to enforce.
    sha=$(gh api "repos/$OWNER/$repo/commits?per_page=1" --jq '.[0].sha' 2>/dev/null || true)
    contexts="[]"
    names=""
    if [ -n "$sha" ]; then
      # Two kinds of check must NOT become required contexts:
      #   - advisory bot reviewers (copilot): they may never report
      #   - release/publish jobs: these are gated to main and report
      #     "skipping" on a PR. GitHub does not count a skipped check as
      #     satisfied, so requiring one blocks every PR forever.
      # Verified on homelabctl PR #25: test=pass, release=skipping.
      names=$(gh api "repos/$OWNER/$repo/commits/$sha/check-runs" \
                --jq '[.check_runs[]
                       | select(.conclusion != "skipped")
                       | .name]
                      | map(select(test("copilot|review|release|publish|deploy"; "i") | not))
                      | unique | .[]' 2>/dev/null || true)
      if [ -n "$names" ]; then
        contexts=$(printf '%s\n' "$names" | jq -R . | jq -sc .)
      fi
    fi

    printf '  %-26s %-8s checks=%s\n' "$repo" "$branch" "$(printf '%s' "$names" | tr '\n' ',' | sed 's/,$//;s/^$/none/')"
    [ "$APPLY" = true ] || continue

    # required_approving_review_count is 0 deliberately: these repos are a
    # single maintainer plus the nightly bot, so requiring a human approval
    # would simply stop every nightly PR. The gate here is CI, not review.
    if gh api -X PUT "repos/$OWNER/$repo/branches/$branch/protection" \
        --input - >/dev/null 2>&1 <<JSON
{
  "required_status_checks": { "strict": true, "contexts": $contexts },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
    then
      echo "      protected"
    else
      echo "      FAILED (private repo on a free plan cannot use protection)"
    fi
  done

echo "=== done ==="
