#!/usr/bin/env bash
# Boot for the task-worker pod (task/Dockerfile). Clone this pod's repo
# list, make sure the agent's home has what the worker expects, then idle:
# the dispatcher execs stage-author/test/merge into the running container.
#
# Deliberately a subset of ../entrypoint.sh. The interactive image also
# seeds a shell/editor home, logs gh and gcloud in, installs tmux plugins
# and starts the always-on Remote Control session; none of that is wanted
# where nobody attaches. Credentials need no boot step either: the Go
# worker hands GH_TOKEN and the Claude token to each tool it runs, and the
# image's system gitconfig routes git through gh.
set -u

workspace="${TASK_WORKSPACE:-/workspace}"
repos_dir="${TASK_REPOS_DIR:-/run/secrets/repos}"
skills_src="${TASK_SKILLS_DIR:-/opt/claude-task/skills}"

# Skills are image-managed: the image wins over whatever the home PVC
# holds, every boot.
if [ -d "$skills_src" ]; then
  mkdir -p "$HOME/.claude/skills" \
    && cp -rf "$skills_src/." "$HOME/.claude/skills/" \
    || echo "WARN: could not seed skills into $HOME/.claude/skills" >&2
fi

# Per-pod repos by StatefulSet ordinal, from the Vault-backed claude-repos
# secret (pod<ordinal> files), falling back to CLONE_REPOS. The worker
# expects /workspace/<repo> to exist; it never clones. Space, comma or
# newline separated; full URLs or owner/repo slugs (assumed github.com).
# Idempotent: a repo dir that exists is left alone, whatever its state.
ORD="${HOSTNAME##*-}"
REPOS="$(cat "$repos_dir/pod${ORD}" 2>/dev/null || echo "${CLONE_REPOS:-}")"
echo "pod ordinal=$ORD -> $(echo "$REPOS" | wc -w) repo(s)"
dirs=()
for r in $(echo "${REPOS:-}" | tr ',\n' '  '); do
  [ -z "$r" ] && continue
  case "$r" in
    http*://*|git@*) url="$r" ;;
    */*)             url="https://github.com/$r.git" ;;
    *)               echo "skip unrecognized repo ref: $r"; continue ;;
  esac
  dir="$workspace/$(basename "$r" .git)"
  dirs+=("$dir")
  if [ -d "$dir/.git" ]; then
    echo "repo present: $dir"
  else
    echo "cloning $url -> $dir"
    git clone "$url" "$dir" || echo "WARN: clone failed: $url"
  fi
done

# Pre-trust the workspace and every repo in it. The worker runs `claude -p`
# with the repo as its working directory; the interactive image found the
# CLI waiting on "Is this a project you trust?" for a directory it had not
# been told about, and nothing is attached here to answer. Keyed by exact
# path, so no trailing slash.
node -e '
const fs = require("fs"), os = require("os"), path = require("path");
const f = path.join(os.homedir(), ".claude.json");
let d = {};
try { d = JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) {}
d.hasCompletedOnboarding = true;
d.projects = d.projects || {};
for (const dir of process.argv.slice(1)) {
  const p = (d.projects[dir] = d.projects[dir] || {});
  p.hasTrustDialogAccepted = true;
  p.hasCompletedProjectOnboarding = true;
}
fs.writeFileSync(f, JSON.stringify(d, null, 2));
' "$workspace" "${dirs[@]}" || echo "WARN: could not write $HOME/.claude.json" >&2

exec sleep infinity
