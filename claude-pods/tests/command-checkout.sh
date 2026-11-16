#!/usr/bin/env bash
# Squashed/deleted published branches must not look like unpushed work.
set -euo pipefail
source "$(dirname "$0")/../lib/pod-common.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
git init -q --bare --initial-branch=main "$tmp/remote"
git clone -q "$tmp/remote" "$tmp/worker" 2>/dev/null
printf base > "$tmp/worker/file"
git -C "$tmp/worker" add file
git -C "$tmp/worker" commit -qm base
git -C "$tmp/worker" push -q origin main
git -C "$tmp/worker" checkout -qb old-task
printf change >> "$tmp/worker/file"
git -C "$tmp/worker" commit -qam task
git -C "$tmp/worker" push -qu origin old-task
git clone -q "$tmp/remote" "$tmp/operator"
git -C "$tmp/operator" merge -q --squash origin/old-task
git -C "$tmp/operator" commit -qm squash
git -C "$tmp/operator" push -q origin main
git -C "$tmp/operator" push -q origin --delete old-task
base=$(git -C "$tmp/operator" rev-parse HEAD)
COMMAND_BRANCH=fix/next
COMMAND_MODE=author
COMMAND_PAYLOAD="$tmp/payload.json"
jq -n --arg base "$base" '{base:"main",baseSHA:$base,branchSHA:""}' > "$COMMAND_PAYLOAD"
# A stale first command must preserve evidence for the subsequent fresh one.
jq -n '{base:"main",baseSHA:"stale",branchSHA:""}' > "$COMMAND_PAYLOAD"
if prepare_command_checkout "$tmp/worker" 2>/dev/null; then
  echo 'stale revision accepted' >&2; exit 1
fi
jq -n --arg base "$base" '{base:"main",baseSHA:$base,branchSHA:""}' > "$COMMAND_PAYLOAD"
prepare_command_checkout "$tmp/worker"
[ "$(git -C "$tmp/worker" rev-parse HEAD)" = "$base" ]
# A truly unpublished commit is preserved and refuses the next checkout.
printf local >> "$tmp/worker/file"
git -C "$tmp/worker" commit -qam unpublished
before=$(git -C "$tmp/worker" rev-parse HEAD)
if prepare_command_checkout "$tmp/worker" 2>/dev/null; then
  echo 'unpublished work was reset' >&2; exit 1
fi
[ "$(git -C "$tmp/worker" rev-parse HEAD)" = "$before" ]
# A resumed branch in a fresh clone must support the promised per-commit push.
COMMAND_BRANCH=fix/resume
COMMAND_MODE=resume
git -C "$tmp/operator" checkout -qb "$COMMAND_BRANCH"
printf resumed >> "$tmp/operator/file"
git -C "$tmp/operator" commit -qam resumed
git -C "$tmp/operator" push -qu origin "$COMMAND_BRANCH"
head=$(git -C "$tmp/operator" rev-parse HEAD)
git clone -q "$tmp/remote" "$tmp/fresh"
jq -n --arg base "$base" --arg head "$head" '{base:"main",baseSHA:$base,branchSHA:$head}' > "$COMMAND_PAYLOAD"
prepare_command_checkout "$tmp/fresh"
[ "$(git -C "$tmp/fresh" rev-parse HEAD)" = "$head" ]
printf continued >> "$tmp/fresh/file"
git -C "$tmp/fresh" commit -qam continued
git -C "$tmp/fresh" -c push.autoSetupRemote=false -c push.default=simple push -q
[ "$(git --git-dir="$tmp/remote" rev-parse "$COMMAND_BRANCH")" = "$(git -C "$tmp/fresh" rev-parse HEAD)" ]
echo 'PASS: published history permits checkout; unpushed work survives; resumed commits push'
