#!/usr/bin/env bash
# Pod 0's nightly job: turn open GitHub issues into reviewed pull requests.
#
# Runs non-interactively via `claude -p`, so everything it needs must be in
# the prompt — there's nobody to answer a question at 00:00. It opens PRs and
# stops; merging is pod 1's job at 04:00, from a cold read of the diff.
#
# Driven by issues, not repos: most of the 24 clones are dormant hobby
# projects, and iterating repos would spend the night on ones with nothing
# to do.
set -uo pipefail

# Preferred model, with a fallback. Fable is first choice, but it sits
# behind a monthly spend cap that Opus does not — and a capped model fails
# every ticket with "You've hit your monthly spend limit" rather than
# degrading. Probed once per run so the job starts using Fable again by
# itself when the cap resets, instead of needing an edit.
MODEL="${NIGHTLY_MODEL:-claude-fable-5-1}"
MODEL_FALLBACK="${NIGHTLY_MODEL_FALLBACK:-opus}"
pick_model() {
  local probe
  probe=$(cd /workspace && timeout 120 claude -p --model "$MODEL" "Reply with exactly: OK" 2>&1 | tail -2)
  if printf '%s' "$probe" | grep -qiE "spend limit|rate limit|not support this model|unavailable"; then
    echo "model $MODEL unavailable ($(printf '%s' "$probe" | head -1)); falling back to $MODEL_FALLBACK" >&2
    MODEL="$MODEL_FALLBACK"
  fi
  echo "using model: $MODEL" >&2
}
MAX_TICKETS="${NIGHTLY_MAX_TICKETS:-3}"
ROUNDS="${NIGHTLY_ROUNDS:-3}"
PER_TICKET_TIMEOUT="${NIGHTLY_TICKET_TIMEOUT:-3600}"
OWNER="${NIGHTLY_OWNER:-ChristopherScot}"
STATE_DIR="${NIGHTLY_STATE_DIR:-/workspace/.nightly}"
LOG="$STATE_DIR/author-$(date +%Y%m%d).log"

# Prompts live as plain files so they can be edited and reviewed on their
# own. Expand $VAR references in them without running the text through a
# shell — the prompts contain backticks and quotes, and `eval` on them
# would be both fragile and an injection path from issue titles.
PROMPT_DIR="${NIGHTLY_PROMPT_DIR:-/usr/local/share/claude-pods/prompts}"
# acceptEdits allows file edits but NOT shell commands, so without an
# explicit allow-list every gh / go test / kubectl call stops for an
# approval nobody is there to give. Scoped list, not bypassPermissions.
NIGHTLY_SETTINGS="${NIGHTLY_SETTINGS:-/usr/local/share/claude-pods/nightly-settings.json}"
render_prompt() {
  local f="$1"
  if [ ! -r "$f" ]; then
    echo "FATAL: prompt not readable: $f" >&2
    exit 1
  fi
  python3 -c '
import os, re, sys
src = open(sys.argv[1]).read()
sys.stdout.write(re.sub(r"\$(\w+)", lambda m: os.environ.get(m.group(1), m.group(0)), src))
' "$f"
}

mkdir -p "$STATE_DIR"
exec > >(tee -a "$LOG") 2>&1
echo "=== nightly-author $(date -Is) model=$MODEL max=$MAX_TICKETS rounds=$ROUNDS ==="

GH_TOKEN="$(cat /run/secrets/git/token 2>/dev/null)"
export GH_TOKEN
if [ -z "$GH_TOKEN" ]; then echo "FATAL: no GitHub token"; exit 1; fi

pick_model

# Clear the sentinel up front: pod 1 keys off it, and a stale one from
# yesterday would let it review a half-finished run as if it were complete.
rm -f "$STATE_DIR/author-done"

# Issues only — the REST API reports PRs under /issues too, and counting
# those is how "4 open tickets" turns into a job with nothing to do.
# Skip anything labelled blocked/wontfix: those need a human, and #25 is
# explicitly blocked on a credential only Chris can create.
collect_tickets() {
  local repo
  for repo in $(tr ',' ' ' < /run/secrets/repos/pod0); do
    if [[ "$repo" != "$OWNER"/* ]]; then
      continue
    fi
    gh api "repos/$repo/issues?state=open&per_page=100" \
      --jq ".[] | select(.pull_request == null)
             | select([.labels[].name] | any(. == \"blocked\" or . == \"wontfix\" or . == \"on-hold\") | not)
             | \"$repo#\(.number)\"" 2>/dev/null
  done
}

mapfile -t TICKETS < <(collect_tickets | head -n "$MAX_TICKETS")

if [ "${#TICKETS[@]}" -eq 0 ]; then
  echo "no actionable open issues; nothing to do"
  date -Is > "$STATE_DIR/author-done"
  exit 0
fi
echo "tickets: ${TICKETS[*]}"

for t in "${TICKETS[@]}"; do
  repo="${t%%#*}"
  num="${t##*#}"
  name="$(basename "$repo")"
  dir="/workspace/$name"
  [ -d "$dir" ] || { echo "SKIP $t: no clone at $dir"; continue; }

  echo "--- $t ($(date -Is))"
  git -C "$dir" fetch --quiet origin 2>/dev/null
  git -C "$dir" checkout --quiet "$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||' || echo main)" 2>/dev/null
  git -C "$dir" reset --hard --quiet origin/HEAD 2>/dev/null

  # Prompt lives in prompts/author.md so it can be edited without touching
  # this script. Exported so render_prompt's subprocess can see them.
  export dir repo num ROUNDS
  render_prompt "$PROMPT_DIR/author.md" > "$STATE_DIR/prompt.txt"
  timeout "$PER_TICKET_TIMEOUT" claude -p --model "$MODEL" \
    --permission-mode acceptEdits --settings "$NIGHTLY_SETTINGS" \
    --add-dir "$dir" < "$STATE_DIR/prompt.txt"

  rc=$?
  [ $rc -eq 124 ] && echo "TIMEOUT after ${PER_TICKET_TIMEOUT}s on $t"

  # Belt and braces on the issue link. The prompt asks for "Closes #N",
  # but a prompt is not a guarantee, and an unlinked PR leaves the ticket
  # open to be picked up again tomorrow night — the same work, twice.
  # Cheap to verify, cheap to repair.
  opened=$(gh pr list --repo "$repo" --head "fix/issue-$num" --state open \
             --json number --jq '.[0].number' 2>/dev/null)
  # A ticket can legitimately end with no PR: the pod may have closed it as
  # obsolete, or skipped it as needing a human. Record which, so a night
  # with no PRs is readable rather than looking like a silent failure.
  if [ -z "$opened" ]; then
    state=$(gh issue view "$num" --repo "$repo" --json state --jq .state 2>/dev/null)
    echo "   no PR for #$num (issue is now ${state:-unknown})"
  fi

  if [ -n "$opened" ]; then
    body=$(gh pr view "$opened" --repo "$repo" --json body --jq .body 2>/dev/null)
    if ! printf '%s' "$body" | grep -qiE "(close[sd]?|fix(e[sd])?|resolve[sd]?) +#$num\b"; then
      echo "   PR #$opened did not link the issue; adding it"
      gh pr edit "$opened" --repo "$repo" \
        --body "Closes #$num

$body" >/dev/null 2>&1 && echo "   linked #$opened -> issue #$num"
    else
      echo "   PR #$opened links issue #$num"
    fi
  fi

  echo "--- $t done rc=$rc"
done

date -Is > "$STATE_DIR/author-done"
echo "=== nightly-author complete $(date -Is) ==="
