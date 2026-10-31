#!/usr/bin/env bash
# Regression test for issue #63: the post-merge sweep must judge each merge
# by the CI run on its own merge commit, revert only the one that broke
# main, and check that the revert actually made main green. It used to
# read `gh run list --limit 1` once per merge — the latest run on main,
# whichever commit that was — so one red run reverted every PR merged
# that night, and the second iteration judged by the first revert's run.
#
# `gh` is replaced by a fake on PATH that records every call and answers
# from canned JSON run through the caller's own `--jq` expression, so the
# script's classification of runs is what gets exercised. PR N's merge
# commit is "sha-N"; the runs on a commit come from $FAKE_RUNS/<sha>.json
# (no file: no runs). A `run list` without `--commit` — what the old code
# issued — answers from latest.json. A revert always opens PR 99.
#
# Run: claude-pods/tests/nightly-merge-sweep.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export FAKE_GH_LOG="$tmp/gh.log" FAKE_RUNS="$tmp/runs"
export NIGHTLY_CI_POLL_SLEEP=0 NIGHTLY_REVERT_RETRY_SLEEP=0
mkdir -p "$tmp/bin" "$FAKE_RUNS"
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
jq_expr=. commit=latest
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --jq)     jq_expr="${args[$((i + 1))]}" ;;
    --commit) commit="${args[$((i + 1))]}" ;;
  esac
done
case "$1 $2" in
  "pr view")   # $3 is a PR number or URL
    printf '{"mergeCommit":{"oid":"sha-%s"}}' "${3##*/}" | jq -r "$jq_expr" ;;
  "run list")
    { [ -f "$FAKE_RUNS/$commit.json" ] && cat "$FAKE_RUNS/$commit.json" || echo '[]'; } | jq -r "$jq_expr" ;;
  "pr revert") echo "https://github.com/example/repo/pull/99" ;;
  "api repos/example/repo") echo "false true" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/gh"
PATH="$tmp/bin:$PATH"

# shellcheck source=../nightly-merge.sh
source "$here/../nightly-merge.sh"

fail() {
  echo "FAIL: $*"
  echo "--- sweep output:"
  printf '%s\n' "$out"
  echo "--- gh calls:"
  cat "$FAKE_GH_LOG" 2>/dev/null
  exit 1
}

run() { printf '[{"status":"completed","conclusion":"%s"}]' "$2" > "$FAKE_RUNS/$1.json"; }

# Starts a scenario: clears the fake's log and runs, and records the given
# "repo pr" merges in merge order.
merges() {
  : > "$FAKE_GH_LOG"
  rm -f "$FAKE_RUNS"/*.json
  printf '%s\n' "$@" > "$tmp/merged"
}
reverted() { grep '^pr revert ' "$FAKE_GH_LOG" | awk '{print $3}' | tr '\n' ' ' | sed 's/ $//'; }

# Two merges, main red after both. The latest run on main (what the old
# code read) is #8's, and it is red — but #7's own run is red too, so #7
# broke main and #8 is only sitting on top of the breakage. Exactly one
# revert, of #7; then the revert's own commit is judged, and it is green.
merges "example/repo 7" "example/repo 8"
run sha-7 failure; run sha-8 failure; run latest failure; run sha-99 success
out=$(post_merge_sweep "$tmp/merged")
[ "$(reverted)" = "7" ] || fail "expected only #7 reverted, got: '$(reverted)'"
grep -q '^run list .*--commit sha-99' "$FAKE_GH_LOG" || fail "the revert's own CI run was never checked"
grep -q 'REVERTED example/repo#7 .*green again' <<<"$out" || fail "revert of #7 was not reported as making main green"

# Same again, but the revert does not fix main: say so, rather than
# claiming the revert worked.
merges "example/repo 7"
run sha-7 failure; run sha-99 failure
out=$(post_merge_sweep "$tmp/merged")
grep -q 'REVERTED example/repo#7 .*NOT green' <<<"$out" || fail "a revert that left main red was not reported as such"

# #7's run was cancelled — the image workflow cancels an in-progress run
# when the next merge lands — and #8's is red. #8's run tested both, so
# either could be at fault: no revert, call a human.
merges "example/repo 7" "example/repo 8"
run sha-7 cancelled; run sha-8 failure; run latest failure
out=$(post_merge_sweep "$tmp/merged")
[ -z "$(reverted)" ] || fail "reverted '$(reverted)' although #7's cancelled run left the blame unclear"
grep -qE 'BROKEN +example/repo#8 .*needs a human' <<<"$out" || fail "unclear blame for #8 was not escalated"

# A merge with no run at all (path-filtered workflows) is neutral: it does
# not cloud the blame for a later red. #7 green, #8 no run, #9 red → #9.
merges "example/repo 7" "example/repo 8" "example/repo 9"
run sha-7 success; run sha-9 failure; run latest failure; run sha-99 success
out=$(post_merge_sweep "$tmp/merged")
[ "$(reverted)" = "9" ] || fail "expected #9 reverted, got: '$(reverted)'"
grep -qE 'no-ci +example/repo#8' <<<"$out" || fail "#8 (no run) was not reported as having nothing to judge"

echo "PASS: one red merge reverts only itself; the revert is re-judged; cancelled runs leave the blame unclear; runless merges are neutral"
