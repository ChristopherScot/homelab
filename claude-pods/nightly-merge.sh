#!/usr/bin/env bash
# Pod 1's 04:00 job: an independent verdict on the PRs pod 0 opened at 00:00.
#
# The point is that this panel has NOT seen pod 0's reasoning. It gets a fresh
# clone and the diff, nothing else — no author transcript, no earlier review
# history. Self-review anchors on its own argument; a cold read does not.
#
# Merge requires BOTH a unanimous panel pass AND green CI. CI is the only
# signal in this system that no agent produced, and two panels of the same
# four agents reading the same diff are correlated, not independent.
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
PER_PR_TIMEOUT="${NIGHTLY_PR_TIMEOUT:-1800}"
OWNER="${NIGHTLY_OWNER:-ChristopherScot}"
STATE_DIR="${NIGHTLY_STATE_DIR:-/workspace/.nightly}"
QUIET_MINUTES="${NIGHTLY_QUIET_MINUTES:-30}"
LOG="$STATE_DIR/merge-$(date +%Y%m%d).log"

# Prompts live as plain files so they can be edited and reviewed on their
# own. Expand $VAR references in them without running the text through a
# shell — the prompts contain backticks and quotes, and `eval` on them
# would be both fragile and an injection path from issue titles.
PROMPT_DIR="${NIGHTLY_PROMPT_DIR:-/usr/local/share/claude-pods/prompts}"
# acceptEdits allows file edits but NOT shell commands, so without an
# explicit allow-list every gh / go test / kubectl call stops for an
# approval nobody is there to give. Scoped list, not bypassPermissions.
NIGHTLY_SETTINGS="${NIGHTLY_SETTINGS:-/usr/local/share/claude-pods/prompts/nightly-settings.json}"
render_prompt() {
  local f="$1"
  if [ ! -r "$f" ]; then
    echo "FATAL: prompt not readable: $f" >&2
    exit 1
  fi
  # node, not python3: python3 is not installed in this image. It appeared
  # to work when probed through an interactive shell, but `kubectl exec`
  # gets a plain PATH and every ticket died on "python3: command not
  # found" before a prompt was ever rendered.
  node -e '
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8");
process.stdout.write(src.replace(/\$(\w+)/g, (m, k) =>
  Object.prototype.hasOwnProperty.call(process.env, k) ? process.env[k] : m));
' "$f"
}

mkdir -p "$STATE_DIR"
# Tee to the PVC log AND to pid 1's stdout, so the run shows up in Loki.
#
# These scripts run under `kubectl exec`, which is a separate process from
# the container's pid 1 (`sleep infinity`, which stops writing after the
# entrypoint finishes). Their output goes to the exec stream and never
# reaches container stdout, so Alloy had nothing to collect and a whole
# 2am run left no trace in Grafana — queryable only as a file inside a
# PVC. Writing to /proc/1/fd/1 puts it where the log collector looks.
#
# Falls back to the file alone if that fd is not writable, rather than
# losing the log entirely.
if [ -w /proc/1/fd/1 ]; then
  exec > >(tee -a "$LOG" > /proc/1/fd/1) 2>&1
else
  exec > >(tee -a "$LOG") 2>&1
fi
echo "=== nightly-merge $(date -Is) model=$MODEL ==="

GH_TOKEN="$(cat /run/secrets/git/token 2>/dev/null)"
export GH_TOKEN
if [ -z "$GH_TOKEN" ]; then echo "FATAL: no GitHub token"; exit 1; fi

# Refuse to start on a credential that cannot work.
#
# ~/.claude/.credentials.json is periodically found with accessToken and
# refreshToken as EMPTY STRINGS and expiresAt=0. Valid JSON, right shape,
# no tokens. Claude Code reads it as expired-in-1970 and cannot renew,
# because the refresh token it would renew with was blanked too.
#
# Cause unknown. It has hit different pods on different nights, and never
# all three at once — so a healthy peer is normally available to copy
# from. Without this check the run burns its whole window failing every
# ticket on "OAuth session expired".
cred_ok() {
  kubectl exec -n "${NIGHTLY_NS:-claude-pods}" "$1" -- node -e '
    const f = process.env.HOME + "/.claude/.credentials.json";
    let d; try { d = require(f).claudeAiOauth; } catch (e) { process.exit(1); }
    if (!d || !d.accessToken || !d.refreshToken) process.exit(1);
    if (!(d.expiresAt > Date.now())) process.exit(1);
  ' >/dev/null 2>&1
}

preflight_credential() {
  local me="${HOSTNAME:-unknown}"
  if cred_ok "$me"; then
    echo "credential: ok"
    return 0
  fi
  echo "credential: INVALID on $me — looking for a healthy peer" >&2
  local peer
  for peer in $(kubectl get pods -n "${NIGHTLY_NS:-claude-pods}" -l app=claude-session                   --field-selector status.phase=Running                   -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    [ "$peer" = "$me" ] && continue
    if cred_ok "$peer"; then
      kubectl exec -n "${NIGHTLY_NS:-claude-pods}" "$peer" -- cat /home/node/.claude/.credentials.json 2>/dev/null         | kubectl exec -i -n "${NIGHTLY_NS:-claude-pods}" "$me" -- sh -c 'umask 077; cat > "$HOME/.claude/.credentials.json"' 2>/dev/null
      if cred_ok "$me"; then
        echo "credential: repaired from $peer" >&2
        return 0
      fi
    fi
  done
  echo "FATAL: no pod has a usable credential; run scripts/claude-pods-login.sh" >&2
  return 1
}

preflight_credential || exit 1

pick_model

now=$(date +%s)

for repo in $(tr ',' ' ' < /run/secrets/repos/pod1); do
  if [[ "$repo" != "$OWNER"/* ]]; then
    continue
  fi

  mapfile -t PRS < <(gh pr list --repo "$repo" --state open --json number,headRefName,updatedAt,headRefOid \
    --jq '.[] | select(.headRefName | startswith("fix/issue-")) | "\(.number) \(.updatedAt) \(.headRefOid)"' 2>/dev/null)
  [ "${#PRS[@]}" -eq 0 ] && continue

  for entry in "${PRS[@]}"; do
    read -r pr updated sha <<<"$entry"

    # Don't judge a branch that is still moving: if pod 0 overran, the diff
    # under review may not be the diff that ends up on the branch.
    upd=$(date -d "$updated" +%s 2>/dev/null || echo 0)
    if [ "$upd" -gt 0 ] && [ $(( (now - upd) / 60 )) -lt "$QUIET_MINUTES" ]; then
      echo "SKIP $repo#$pr: updated $(( (now - upd) / 60 ))m ago, still settling"
      continue
    fi

    # Pod 2's integration testing gates the merge. Its tests are manual and
    # non-deterministic — they exercise the running software, so they cannot
    # live in CI — which means this is the only place that signal is
    # enforced. No verdict means not tested, never "nothing found": a pod 2
    # that timed out or crashed must not read as approval.
    #
    # Read on this head commit, not from a label: a label stays on the
    # pull request through a force-push, so a pass earned on code that
    # has since been replaced would read as a pass for the replacement.
    # A status belongs to the commit it was posted against, so a new
    # head simply has none and falls through to the untested path.
    # The combined status reports one entry per context, the latest, so
    # a SHA retested after a fix reads as the retest.
    state=$(gh api "repos/$repo/commits/$sha/status" \
      --jq '.statuses[] | select(.context == "nightly/integration") | .state' 2>/dev/null | head -1)
    case "$state" in
      success) tested=PASS ;;
      failure) tested=FAIL ;;
      error)   tested=BLOCKED ;;
      *)       tested="" ;;
    esac
    case "${tested:-NONE}" in
      PASS) : ;;
      FAIL)
        echo "NO-MERGE $repo#$pr: pod 2 integration testing FAILED"
        gh pr comment "$pr" --repo "$repo" --body "Nightly review (pod 1): not merged — pod 2's integration testing reported FAIL. See its comment above." >/dev/null 2>&1
        continue
        ;;
      *)
        echo "NO-MERGE $repo#$pr: no pod 2 verdict at $sha — untested, not approved"
        gh pr comment "$pr" --repo "$repo" --body "Nightly review (pod 1): not merged — no integration-test verdict from pod 2 for \`${sha:0:7}\`. An untested change is not an approved one; leaving this for a human." >/dev/null 2>&1
        continue
        ;;
    esac

    # CI must be green on its own merits before any agent opinion counts.
    checks=$(gh pr checks "$pr" --repo "$repo" 2>&1)
    if echo "$checks" | grep -qiE '\b(fail|failure|error)\b'; then
      echo "NO-MERGE $repo#$pr: CI not green"
      gh pr comment "$pr" --repo "$repo" --body "Nightly review (pod 1): not merged — CI is not green." >/dev/null 2>&1
      continue
    fi
    if echo "$checks" | grep -qiE '\b(pending|in_progress|queued)\b'; then
      echo "SKIP $repo#$pr: CI still running"
      continue
    fi

    name="$(basename "$repo")"
    dir="/workspace/$name"
    [ -d "$dir" ] || { echo "SKIP $repo#$pr: no clone"; continue; }
    git -C "$dir" fetch --quiet origin 2>/dev/null

    echo "--- reviewing $repo#$pr ($(date -Is))"
    # Heredoc written to a file first: nesting one inside $( ) trips bash's
    # parser on ordinary apostrophes in the prompt text.
    # Prompt lives in prompts/review.md so it can be edited without touching
    # this script. Exported so render_prompt's subprocess can see them.
    export dir repo pr
    render_prompt "$PROMPT_DIR/review.md" > "$STATE_DIR/prompt.txt"
    verdict=$(timeout "$PER_PR_TIMEOUT" claude -p --model "$MODEL" \
      --permission-mode acceptEdits --settings "$NIGHTLY_SETTINGS" --add-dir "$dir" < "$STATE_DIR/prompt.txt")
    rc=$?
    [ $rc -eq 124 ] && { echo "TIMEOUT on $repo#$pr"; continue; }

    echo "$verdict" | tail -20
    decision=$(printf '%s' "$verdict" | grep -oE '^VERDICT: (MERGE|NO-MERGE|RISKY)' | tail -1 | awk '{print $2}')

    case "$decision" in
      MERGE)
        # Merge method is per-repo and squash is disabled across all of
        # these, so asking for it unconditionally fails every merge
        # ("Squash merges are not allowed on this repository"). Pick a
        # method the repo actually permits.
        method="--merge"
        case "$(gh api "repos/$repo" --jq '"\(.allow_squash_merge) \(.allow_merge_commit)"' 2>/dev/null)" in
          "true "*) method="--squash" ;;
          *" true") method="--merge" ;;
          *)        method="--rebase" ;;
        esac
        # Pinned to the commit whose verdict was read: the review agent
        # above can run for most of an hour, and a push landing in that
        # window would otherwise be merged carrying a pass earned on the
        # commit it replaced. GitHub refuses the merge instead, which the
        # failure path below already handles.
        if gh pr merge "$pr" --repo "$repo" $method \
          --match-head-commit "$sha" --delete-branch >/dev/null 2>&1; then
          echo "MERGED $repo#$pr"
          # Recorded so the post-merge sweep below can revert it if main
          # goes red. Merging is only safe because undoing it is cheap.
          echo "$repo $pr" >> "$STATE_DIR/merged-$(date +%Y%m%d)"
          gh pr comment "$pr" --repo "$repo" --body "Nightly review (pod 1, independent panel): merged." >/dev/null 2>&1
        else
          echo "MERGE FAILED $repo#$pr"
        fi
        ;;
      RISKY)
        # Deliberately louder than NO-MERGE: the code may be correct, so
        # this is the case most likely to be waved through on a skim.
        echo "RISKY $repo#$pr — flagged for human decision"
        gh pr edit "$pr" --repo "$repo" --add-label "risky" >/dev/null 2>&1 \
          || gh label create risky --repo "$repo" --color B60205 \
               --description "Nightly review flagged this as too high blast-radius to auto-merge" >/dev/null 2>&1 \
          && gh pr edit "$pr" --repo "$repo" --add-label "risky" >/dev/null 2>&1
        gh pr comment "$pr" --repo "$repo" --body "## Nightly review (pod 1): RISKY — not merged

The change may well be correct; the concern is blast radius, not quality.
This one wants a human decision before it lands.

$(printf '%s' "$verdict" | tail -30)" >/dev/null 2>&1
        ;;
      NO-MERGE)
        echo "HELD $repo#$pr"
        gh pr comment "$pr" --repo "$repo" --body "Nightly review (pod 1, independent panel): held for human review.

$(printf '%s' "$verdict" | tail -30)" >/dev/null 2>&1
        ;;
      *)
        # No parseable verdict means the run broke, not that the PR is good.
        echo "HELD $repo#$pr: no verdict parsed"
        ;;
    esac
  done
done

# Post-merge sweep: a green PR check is not the same as a green main — the
# merge itself can break things (squashed semantic conflict, two PRs fine
# apart and broken together). Wait for main's CI, and revert anything that
# turned it red. Reverting fast beats agonising over the merge decision.
MERGED_FILE="$STATE_DIR/merged-$(date +%Y%m%d)"
if [ -s "$MERGED_FILE" ]; then
  echo "=== post-merge verification $(date -Is) ==="
  sort -u "$MERGED_FILE" | while read -r repo pr; do
    [ -z "$repo" ] && continue

    # Give main's run time to start and finish before judging it.
    status=""
    for _ in $(seq 1 40); do
      status=$(gh run list --repo "$repo" --branch main --limit 1 \
                 --json status,conclusion --jq '.[0] | "\(.status) \(.conclusion)"' 2>/dev/null)
      if [[ "$status" == completed\ * ]]; then
        break
      fi
      sleep 30
    done

    if [[ "$status" == "completed success" ]]; then
      echo "   ok      $repo#$pr (main green)"
    elif [[ "$status" == completed\ * ]]; then
      outcome="${status#completed }"
      echo "   BROKEN  $repo#$pr -> main is $outcome; reverting"
      if gh pr revert "$pr" --repo "$repo" --merge >/dev/null 2>&1; then
        echo "   REVERTED $repo#$pr"
        gh pr comment "$pr" --repo "$repo" --body \
          "Nightly: this merge turned main $outcome, so it has been reverted automatically. The branch work is preserved in the revert's parent commit." >/dev/null 2>&1
      else
        # A failed revert is worse than a failed merge: main stays broken
        # and nobody is watching until morning. Say so loudly in the log.
        echo "   REVERT FAILED $repo#$pr — main left broken, needs a human"
        gh pr comment "$pr" --repo "$repo" --body \
          "Nightly: this merge turned main $outcome and the automatic revert FAILED. main needs manual attention." >/dev/null 2>&1
      fi
    else
      echo "   UNKNOWN $repo#$pr (main CI still '$status' after 20m; not reverting)"
    fi
  done
fi

echo "=== nightly-merge complete $(date -Is) ==="
