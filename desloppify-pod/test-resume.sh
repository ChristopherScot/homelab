#!/usr/bin/env bash
# A run killed between `gh stack add` and `gh stack submit` must be
# resumable, not fatal.
#
# The branch it created is in the stack locally and has no PR on GitHub.
# Every stack lookup in nightly-desloppify.sh went through OPEN PRs, so
# that branch was invisible to all of them: the next run fell through to
# `gh stack init`, died on "current branch is already part of a stack",
# and so did every run after it. One KEDA scale-to-0 at 06:30 on
# 2026-11-14 wedged the pod until a human intervened; a node eviction or
# an OOM reaches the same state.
#
# The fix reads `gh stack view --json`, which is local and therefore does
# see the unsubmitted branch. This pins the selector that decides, because
# the cost of getting it wrong is asymmetric: resuming the wrong branch
# rewrites work somebody is reviewing.
#
# Run: desloppify-pod/test-resume.sh
set -uo pipefail
fail=0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/nightly-desloppify.sh"

# The selector, lifted verbatim from the script so the two cannot drift.
# If this extraction finds nothing the test fails loudly rather than
# silently testing a stale copy of the expression.
sel_expr=$(sed -n "/resume_branch=\$(printf/,/name \/\/ empty/p" "$script" \
           | sed -e "s/.*jq -r '//" -e "s/' 2>.*$//" -e "s/^ *//" \
           | tr '\n' ' ')
if ! printf '%s' "$sel_expr" | grep -q 'branches'; then
  # Fall back to the literal, but say so - a silent fallback would let
  # the script's expression change without this test noticing.
  echo "NOTE: could not lift the selector from the script; using the literal"
  sel_expr='.branches | last | select(.pr == null)
            | select(.name | startswith("desloppify/")) | .name // empty'
fi

sel() { printf '%s' "$1" | jq -r "$sel_expr" 2>/dev/null; }

check() {
  local what=$1 json=$2 want=$3 got
  got=$(sel "$json")
  if [ "$got" != "$want" ]; then
    echo "FAIL: $what"
    echo "      want [$want] got [$got]"
    fail=1
  fi
}

# Resume: the top of the stack is a desloppify branch with no PR. This is
# the shape the 2026-11-14 kill left behind.
# gh stack omits the pr key entirely when a branch has no PR - verified
# against the installed binary, which emits
# {"name":...,"isCurrent":true,"isMerged":false,...} with no pr field.
# Fixtures that say "pr": null would also pass a selector written as
# `has("pr") and .pr == null`, which never fires in production.
check "resumes an unsubmitted top branch" \
  '{"branches":[{"name":"desloppify/webapp-1","pr":17094},
                {"name":"desloppify/webapp-2","isCurrent":true}]}' \
  "desloppify/webapp-2"

check "resumes when it is the only branch" \
  '{"branches":[{"name":"desloppify/webapp-1","isCurrent":true}]}' \
  "desloppify/webapp-1"

# Do NOT resume. Each of these would be a different bug if it did.
check "leaves a fully submitted stack alone" \
  '{"branches":[{"name":"desloppify/webapp-1","pr":17094},
                {"name":"desloppify/webapp-2","pr":17095}]}' \
  ""

# A PR-less branch BELOW the top is somebody mid-review or a closed PR,
# not an unfinished run. Adopting it would rewrite work being read.
check "ignores a gap below the top" \
  '{"branches":[{"name":"desloppify/webapp-1","isCurrent":true},
                {"name":"desloppify/webapp-2","pr":17095}]}' \
  ""

# A human branch at the top of the stack is not this pod's to take over.
check "ignores a non-desloppify branch at the top" \
  '{"branches":[{"name":"desloppify/webapp-1","pr":17094},
                {"name":"chris/wip","isCurrent":true}]}' \
  ""

check "handles an empty stack" '{"branches":[]}' ""
check "handles malformed json" 'not json at all' ""
check "handles a missing branches key" '{"trunk":"x"}' ""

# The resume path must not call `gh stack sync`. sync rebases the whole
# stack and force-pushes it; the resumed branch has never been pushed, so
# there is nothing to reconcile, and a conflict there would strand the run
# in the state this fix exists to recover from.
resume_block=$(awk '/^if \[ -n "\$resume_branch" \]; then/{n++} n==2{print} /^elif \[ -n "\$prev_pr" \]/{if(n==2) exit}' "$script")
# Code lines only: the block's own comment explains why sync is not
# called, and matching that would fail on the explanation rather than
# the behaviour.
if printf '%s' "$resume_block" | grep -v '^ *#' | grep -q 'gh stack sync'; then
  echo "FAIL: the resume path calls gh stack sync"
  echo "      a conflict there re-strands the run it is recovering"
  fail=1
fi
if ! printf '%s' "$resume_block" | grep -q 'git checkout'; then
  echo "FAIL: the resume path does not check the branch out"
  fail=1
fi

# And it must come BEFORE the prev_pr branch, or the open-PR lookup wins
# and the unsubmitted branch stays invisible.
resume_at=$(grep -n '^if \[ -n "\$resume_branch" \]' "$script" | tail -1 | cut -d: -f1)
prevpr_at=$(grep -n '^elif \[ -n "\$prev_pr" \]' "$script" | head -1 | cut -d: -f1)
if [ -z "$resume_at" ] || [ -z "$prevpr_at" ] || [ "$resume_at" -ge "$prevpr_at" ]; then
  echo "FAIL: the resume check must precede the prev_pr check"
  echo "      resume at [$resume_at], prev_pr at [$prevpr_at]"
  fail=1
fi

# A branch whose PR was CLOSED is indistinguishable from one never
# submitted: gh stack re-resolves tracked PRs through a states:[OPEN]
# query, gets nothing, and drops the pr field. Adopting one would pile
# commits onto work a human deliberately closed. The discriminator is a
# remote ref - never submitted means never pushed.
if ! grep -q 'rev-parse --verify -q "origin/\$resume_branch"' "$script"; then
  echo "FAIL: no remote-ref check, so a closed-PR branch would be adopted"
  fail=1
fi
# It has to run BEFORE the branch is adopted, or it guards nothing.
refcheck_at=$(grep -n 'rev-parse --verify -q "origin/\$resume_branch"' "$script" | head -1 | cut -d: -f1)
adopt_at=$(grep -n 'branch="\$resume_branch"' "$script" | head -1 | cut -d: -f1)
if [ -z "$refcheck_at" ] || [ -z "$adopt_at" ] || [ "$refcheck_at" -ge "$adopt_at" ]; then
  echo "FAIL: the remote-ref check must precede adopting the branch"
  echo "      check at [$refcheck_at], adopt at [$adopt_at]"
  fail=1
fi

# `git clean -qfd` deletes untracked files, and on a resumed branch those
# ARE the unfinished work. The fixture this was first run against held
# four new source files - three tests and a util - that an unconditional
# clean would have destroyed before the agent started. It must be gated
# on not resuming.
clean_line=$(grep -vn '^ *#' "$script" | grep 'git -C "\$dir" clean -qfd' \
             | head -1 | cut -d: -f1)
if [ -z "$clean_line" ]; then
  echo "FAIL: cannot find the git clean call to check it is gated"
  fail=1
else
  guard=$(sed -n "$((clean_line - 1))p" "$script")
  case "$guard" in
    *'-z "$resume_branch"'*) ;;
    *)
      echo "FAIL: git clean -qfd is not gated on a fresh branch"
      echo "      a resumed run would delete its own untracked work"
      fail=1 ;;
  esac
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: resume adopts an unsubmitted top branch, ignores every other shape, and runs before the open-PR lookup"
fi
exit "$fail"
