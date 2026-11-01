#!/usr/bin/env bash
# Pod 2's job: try hard to break the PRs pod 0 opened, and file issues for
# what actually breaks.
#
# Runs at 02:00, between authoring (00:00) and the merge verdict (04:00),
# so anything it finds is on the PR before pod 1 decides. A bug found at
# 02:00 is a NO-MERGE at 04:00; the same bug found after the merge is a
# revert.
#
# Deliberately separate from pod 1. Pod 1 asks "is this good code?" and
# pod 2 asks "where does it break?" — different questions, and bundling
# them means the second gets answered carelessly once the first looks fine.
set -uo pipefail

# Shared preamble for the three nightly pods — see lib/nightly-common.sh.
# A fix there reaches all three.
NIGHTLY_LIB="${NIGHTLY_LIB:-/usr/local/share/claude-pods/lib/nightly-common.sh}"
# shellcheck source=lib/nightly-common.sh
source "$NIGHTLY_LIB" || { echo "FATAL: cannot source $NIGHTLY_LIB" >&2; exit 1; }

PER_PR_TIMEOUT="${NIGHTLY_PR_TIMEOUT:-2700}"
QUIET_MINUTES="${NIGHTLY_QUIET_MINUTES:-30}"
LOG="$STATE_DIR/test-$(date +%Y%m%d).log"

mkdir -p "$STATE_DIR"
log_to "$LOG"
echo "=== nightly-test $(date -Is) ==="

require_gh_token || exit 1
preflight_credential || exit 1

pick_model

now=$(date +%s)

for repo in $(tr ',' ' ' < /run/secrets/repos/pod2); do
  if [[ "$repo" != "$OWNER"/* ]]; then
    continue
  fi

  mapfile -t PRS < <(gh pr list --repo "$repo" --state open --json number,headRefName,updatedAt \
    --jq '.[] | select(.headRefName | startswith("fix/issue-")) | "\(.number) \(.updatedAt)"' 2>/dev/null)
  [ "${#PRS[@]}" -eq 0 ] && continue

  for entry in "${PRS[@]}"; do
    pr="${entry%% *}"
    updated="${entry##* }"

    # Don't test a branch pod 0 may still be pushing to.
    upd=$(date -d "$updated" +%s 2>/dev/null || echo 0)
    if [ "$upd" -gt 0 ] && [ $(( (now - upd) / 60 )) -lt "$QUIET_MINUTES" ]; then
      echo "SKIP $repo#$pr: updated $(( (now - upd) / 60 ))m ago, still settling"
      continue
    fi

    name="$(basename "$repo")"
    dir="/workspace/$name"
    [ -d "$dir" ] || { echo "SKIP $repo#$pr: no clone"; continue; }
    git -C "$dir" fetch --quiet origin 2>/dev/null

    echo "--- testing $repo#$pr ($(date -Is))"
    export dir repo pr
    render_prompt "$PROMPT_DIR/test.md" > "$STATE_DIR/test-prompt.txt"

    out=$(timeout "$PER_PR_TIMEOUT" claude -p --model "$MODEL" \
      --permission-mode acceptEdits --settings "$NIGHTLY_SETTINGS" --add-dir "$dir" < "$STATE_DIR/test-prompt.txt")
    rc=$?
    printf '%s\n' "$out" | tail -25

    # The verdict gates the merge, so record it where pod 1 will look. A
    # timeout or crash is NOT a pass: absence of a verdict must read as
    # "not tested", never as "nothing found".
    verdict=$(printf '%s' "$out" | grep -oE '^TESTED: (PASS|FAIL|BLOCKED)' | tail -1 | awk '{print $2}')
    if [ $rc -eq 124 ]; then
      echo "TIMEOUT on $repo#$pr"
      verdict="BLOCKED"
    fi
    # Publish the verdict ON THE PR, not to local state: pod 1 runs in a
    # different pod with its own PVC and cannot read this filesystem.
    # A label is also visible to a human scanning the PR list.
    verdict="${verdict:-BLOCKED}"
    for l in tested-pass tested-fail tested-blocked; do
      gh pr edit "$pr" --repo "$repo" --remove-label "$l" >/dev/null 2>&1
    done
    want="tested-$(printf '%s' "$verdict" | tr '[:upper:]' '[:lower:]')"
    gh label create "$want" --repo "$repo" --color ededed \
      --description "Nightly integration-test verdict from pod 2" >/dev/null 2>&1
    gh pr edit "$pr" --repo "$repo" --add-label "$want" >/dev/null 2>&1 \
      && echo "   labelled $repo#$pr $want"
    echo "${repo} ${pr} ${verdict}" >> "$STATE_DIR/tested-$(date +%Y%m%d)"
    echo "--- $repo#$pr done rc=$rc verdict=${verdict:-BLOCKED}"

    # Leave no scratch tests behind: the next stage checks out this same
    # clone, and a stray failing file would be blamed on the PR.
    git -C "$dir" reset --hard --quiet 2>/dev/null
    git -C "$dir" clean -qfd 2>/dev/null
  done
done

echo "=== nightly-test complete $(date -Is) ==="
