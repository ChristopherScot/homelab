#!/usr/bin/env bash
# task/entrypoint.sh boots a worker pod with no human attached, so a wrong
# turn is silent: a repo it fails to clone is a stage that fails hours
# later with "no such directory". This drives it against a fake git and a
# fake secrets tree and checks what it cloned, with what credential, what
# it left alone, what it trusted, and that it idled rather than exited.
#
# Run: claude-pods/tests/task-entrypoint.sh
set -uo pipefail
fail=0
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$here/task/entrypoint.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/secrets/repos" "$tmp/secrets/git" \
         "$tmp/workspace/present/.git" "$tmp/skills/kernel" "$tmp/home"
# The fake git records its arguments and the token it was handed.
cat > "$tmp/bin/git" <<EOF
#!/bin/sh
echo "git \$* token=\${GH_TOKEN:-unset}" >> "$tmp/calls.log"
EOF
# `exec sleep infinity` must be the last thing it does; a fake sleep
# turns that into a clean exit the test can observe.
cat > "$tmp/bin/sleep" <<EOF
#!/bin/sh
echo "sleep \$*" >> "$tmp/calls.log"
EOF
# Anything interactive reaching for tmux is a regression.
cat > "$tmp/bin/tmux" <<EOF
#!/bin/sh
echo "tmux \$*" >> "$tmp/calls.log"
exit 1
EOF
chmod +x "$tmp/bin/"*
printf 'kernel skill\n' > "$tmp/skills/kernel/SKILL.md"
printf 'ghp_fake\n' > "$tmp/secrets/git/token"
# pod0's list: one already present, one slug, one full URL, one junk ref.
printf 'owner/present, owner/missing\nhttps://example.com/elsewhere.git\njunk\n' > "$tmp/secrets/repos/pod0"

run() {
  : > "$tmp/calls.log"
  HOSTNAME=$1 HOME="$tmp/home" PATH="$tmp/bin:$PATH" \
    TASK_WORKSPACE="$tmp/workspace" TASK_SECRETS_DIR="$tmp/secrets" TASK_SKILLS_DIR="$tmp/skills" \
    bash "$script" 2>&1
}

check() {
  local what=$1 want=$2 got=$3
  if [ "$want" != "$got" ]; then
    echo "FAIL: $what"
    echo "      want [$want] got [$got]"
    fail=1
  fi
}

out=$(run claude-task-0); rc=$?
check "entrypoint exits cleanly once its fake sleep returns" 0 "$rc"

# 1. Clones exactly the repos that are listed and absent, by the right URL,
#    with the mounted token in git's environment.
check "clones the missing slug from github.com with the token" 1 \
  "$(grep -c "git clone https://github.com/owner/missing.git $tmp/workspace/missing token=ghp_fake" "$tmp/calls.log")"
check "clones the full URL as given" 1 \
  "$(grep -c "git clone https://example.com/elsewhere.git $tmp/workspace/elsewhere token=ghp_fake" "$tmp/calls.log")"
check "leaves a present repo alone" 0 "$(grep -c 'clone.*present' "$tmp/calls.log")"
check "skips an unrecognized ref" 0 "$(grep -c 'junk' "$tmp/calls.log")"
printf '%s' "$out" | grep -q 'skip unrecognized repo ref: junk' \
  || { echo "FAIL: an unrecognized ref is not reported"; fail=1; }
check "total clones" 2 "$(grep -c 'git clone' "$tmp/calls.log")"

# 2. Reads the list for ITS ordinal, not pod0's by habit.
printf 'owner/other\n' > "$tmp/secrets/repos/pod2"
run claude-task-2 >/dev/null
check "ordinal 2 clones pod2's list" 1 "$(grep -c 'clone.*owner/other' "$tmp/calls.log")"
check "ordinal 2 does not clone pod0's list" 0 "$(grep -c 'clone.*owner/missing' "$tmp/calls.log")"

# 3. A missing token is reported, not fatal: public repos still clone.
rm "$tmp/secrets/git/token"
out=$(run claude-task-2)
printf '%s' "$out" | grep -q 'no git token' || { echo "FAIL: a missing token is not reported"; fail=1; }
check "still clones without a token" 1 "$(grep -c 'clone.*owner/other.* token=unset' "$tmp/calls.log")"

# 4. Trusts the workspace and each listed repo, keyed by exact path.
for dir in "$tmp/workspace" "$tmp/workspace/present" "$tmp/workspace/missing" "$tmp/workspace/elsewhere"; do
  jq -e --arg d "$dir" '.projects[$d].hasTrustDialogAccepted == true' "$tmp/home/.claude.json" >/dev/null 2>&1 \
    || { echo "FAIL: $dir is not pre-trusted in .claude.json"; fail=1; }
done

# 5. Seeds skills from the image and then idles; nothing interactive.
test -f "$tmp/home/.claude/skills/kernel/SKILL.md" || { echo "FAIL: skills not seeded into HOME"; fail=1; }
check "ends in sleep infinity" 1 "$(grep -c '^sleep infinity$' "$tmp/calls.log")"
check "never touches tmux" 0 "$(grep -c '^tmux' "$tmp/calls.log")"

[ "$fail" -eq 0 ] && echo "PASS: task entrypoint clones its ordinal's missing repos with the mounted token, trusts them, seeds skills and idles"
exit "$fail"
