#!/usr/bin/env bash
# Regression test for issue #60: the post-merge sweep must actually land a
# revert on main. It used to call `gh pr revert --merge`, a flag gh does
# not have, so every broken-main revert failed before reaching GitHub.
#
# `gh` is replaced by a fake on PATH that accepts exactly the flags the
# real `gh pr revert` does (gh 2.103: -b/--body, -F/--body-file,
# -d/--draft, -t/--title, -R/--repo), rejecting anything else the way gh
# does, and records every call. The test then checks that the revert PR
# the fake "opens" is merged, since `gh pr revert` only opens one.
#
# Run: claude-pods/tests/nightly-merge-revert.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export FAKE_GH_LOG="$tmp/gh.log"
# How many `pr merge` attempts the fake refuses before accepting one.
export FAKE_GH_MERGE_FAILS=0
export NIGHTLY_REVERT_RETRY_SLEEP=0
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "$1 $2" in
  "pr revert")
    shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        -b|--body|-F|--body-file|-t|--title|-R|--repo) shift 2 ;;
        -d|--draft) shift ;;
        -*) echo "unknown flag: $1" >&2; exit 1 ;;
        *) shift ;;  # the PR selector
      esac
    done
    echo "https://github.com/example/repo/pull/99"
    ;;
  "pr merge")
    # The log already holds this call, so the count includes it.
    [ "$(grep -c '^pr merge ' "$FAKE_GH_LOG")" -le "$FAKE_GH_MERGE_FAILS" ] && exit 1
    exit 0
    ;;
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
  echo "--- gh calls:"
  cat "$FAKE_GH_LOG" 2>/dev/null
  exit 1
}

revert_url="https://github.com/example/repo/pull/99"

url=$(revert_pr example/repo 7) || fail "revert_pr returned non-zero (gh rejected the revert?)"
[ "$url" = "$revert_url" ] || fail "unexpected URL from revert_pr: '$url'"
grep -q "^pr merge $revert_url .*--merge" "$FAKE_GH_LOG" \
  || fail "revert PR 99 was opened but never merged (with the repo's permitted method), so main would stay broken"

# GitHub computes a brand-new PR's mergeability asynchronously and refuses
# a merge until it has; a refusal in that window must be retried, not
# reported as a failed revert.
: > "$FAKE_GH_LOG"
FAKE_GH_MERGE_FAILS=2
revert_pr example/repo 7 >/dev/null || fail "revert_pr gave up on a merge that was refused only twice"
[ "$(grep -c '^pr merge ' "$FAKE_GH_LOG")" -eq 3 ] \
  || fail "expected 3 merge attempts (2 refused, 1 accepted)"

# The failure path must be honest: an unmerged revert PR is not a revert,
# but its URL is still reported so the morning human can find it.
: > "$FAKE_GH_LOG"
FAKE_GH_MERGE_FAILS=99
if url=$(revert_pr example/repo 7 2>/dev/null); then
  fail "revert_pr reported success although the revert PR could not be merged"
fi
[ "$url" = "$revert_url" ] || fail "unmerged revert PR's URL was not reported: '$url'"

echo "PASS: revert of #7 opened PR 99 and merged it; a transient refusal is retried; an unmergeable revert fails but reports its URL"
