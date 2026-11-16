#!/usr/bin/env bash
# Run by claude-task-image.yml inside the freshly built image with
# --network=none, a read-only root and empty /home/node and /workspace:
# everything the worker, the dispatcher's launch line and the agent's
# allow-list need must come from the image alone, and nothing interactive
# may have crept back in. A failure here stops the publish.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

test "$(id -u)" = 1000 || fail "not running as uid 1000"
test -w "$HOME" || fail "$HOME is not writable"

# The worker and what it execs: git, gh, claude, bash for maintenance.sh.
# flock/setsid/nohup/mktemp are what the dispatcher's launch line and busy
# probe run through `sh -c` in this container; pkill is what the preStop
# hook sends the worker.
for tool in kaneo-worker stop-kaneo-worker stage-author stage-test stage-merge \
            claude git gh bash sh flock setsid nohup mktemp timeout pkill; do
  command -v "$tool" >/dev/null || fail "missing worker tool: $tool"
done
# The hook on an idle pod: no worker to signal, nothing holding the lock.
NIGHTLY_LOCK=/tmp/smoke.lock stop-kaneo-worker || fail "stop-kaneo-worker failed on an idle pod"
# Build/test tools the image is meant to ship for the agent. This is the
# image's contract, not a transcription of the allow-list: that file also
# permits golangci-lint, python3 and pytest, which neither image installs.
for tool in go gofmt make gcc node npm npx tsc tsx jq yq rg curl \
            kubectl helm tofu agent-browser kbrowser; do
  command -v "$tool" >/dev/null || fail "missing build/test tool: $tool"
done

# Interactive-only tooling must be gone.
for tool in tmux nvim vim zsh gcloud gsutil starship zoxide eza fzf lazygit \
            delta direnv croc kaneo dlv gopls goimports gofumpt \
            rclaude-layout tmux-sessionizer dp; do
  ! command -v "$tool" >/dev/null || fail "interactive tool present: $tool"
done
test ! -e /opt/home-skel || fail "/opt/home-skel (interactive home skeleton) present"

# The worker binary runs and refuses the wrong argv before touching anything.
rc=0; kaneo-worker >/dev/null 2>&1 || rc=$?
test "$rc" = 2 || fail "kaneo-worker without arguments exited $rc, expected usage (2)"
# Each entrypoint carries the protocol marker the dispatcher greps for and
# execs the worker, which rejects an empty command id before credentials.
for stage in author test merge; do
  script=/usr/local/bin/stage-$stage
  test -x "$script" || fail "$script is not executable"
  grep -qx '# dispatcher-command-protocol: 3' "$script" || fail "$script lacks protocol marker 3"
  rc=0; "$script" task owner/repo '' >/dev/null 2>&1 || rc=$?
  test "$rc" = 1 || fail "$script with an empty command id exited $rc, expected 1"
done

# What the worker looks for by path.
settings=/usr/local/share/claude-pods/prompts/nightly-settings.json
jq -e '.permissions.allow | length > 0' "$settings" >/dev/null || fail "$settings has no allow-list"
bash /usr/local/share/claude-pods/lib/maintenance.sh warn || fail "maintenance.sh warn failed"
test -n "${TASK_SKILLS_DIR:-}" || fail "TASK_SKILLS_DIR is not set in the image environment"
test -f "$TASK_SKILLS_DIR/kernel/SKILL.md" || fail "kernel skill not baked under $TASK_SKILLS_DIR"

# git goes through gh, which reads the GH_TOKEN the worker injects.
git config --system --get-all credential.https://github.com.helper | grep -q 'gh auth git-credential' \
  || fail "system gitconfig does not route github.com credentials through gh"
test "${DISABLE_UPDATES:-}" = 1 || fail "DISABLE_UPDATES is not set in the image environment"

# The CLI starts offline.
claude --version >/dev/null || fail "claude --version failed"
go version >/dev/null
kubectl version --client >/dev/null
helm version >/dev/null
tofu version >/dev/null

# The entrypoint reaches its idle loop with no repo list and no network:
# timeout(1) reports 124 when it had to kill the sleep.
rc=0; timeout 5 /usr/local/bin/entrypoint >/dev/null 2>&1 || rc=$?
test "$rc" = 124 || fail "entrypoint exited $rc before idling"
test -f "$HOME/.claude.json" || fail "entrypoint did not write $HOME/.claude.json"
test -f "$HOME/.claude/skills/kernel/SKILL.md" || fail "entrypoint did not seed skills"

echo "PASS: task image carries the worker, its entrypoints and tools, and no interactive tooling ($(claude --version))"
