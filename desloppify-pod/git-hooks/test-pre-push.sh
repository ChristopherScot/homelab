#!/usr/bin/env bash
# Exercises pre-push against real pushes to a real local remote.
#
# Feeding the hook stdin by hand tests the parsing but not the wiring: a
# hook that git never invokes passes every such test. This pushes for
# real, and asserts the remote's main did not move.
set -uo pipefail
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pre-push"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

git init -q --bare "$tmp/remote"
git init -q "$tmp/work"
cd "$tmp/work"
git config user.email t@t.t; git config user.name t
git symbolic-ref HEAD refs/heads/main
echo one > a.txt; git add a.txt; git commit -qm init
git remote add origin "$tmp/remote"

# Without the hook the push must work, or a later refusal proves nothing.
if ! git push -q origin main 2>/dev/null; then
  echo "FAIL: baseline push to main was refused before the hook existed"
  exit 1
fi
first=$(git rev-parse HEAD)

install -m 755 "$HOOK" .git/hooks/pre-push
echo two >> a.txt; git commit -qam second

for spec in "main" "HEAD:main" "HEAD:refs/heads/main" "main --force"; do
  if git push origin $spec >/dev/null 2>&1; then
    echo "FAIL: push to '$spec' was allowed"; fail=1
  fi
done

git checkout -qb desloppify/probe
if ! git push -q origin desloppify/probe 2>/dev/null; then
  echo "FAIL: a work branch was refused"; fail=1
fi

if [ "$(git --git-dir="$tmp/remote" rev-parse refs/heads/main)" != "$first" ]; then
  echo "FAIL: main on the remote advanced"; fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS - pre-push refuses protected branches, allows work branches"
exit "$fail"
