#!/usr/bin/env bash
# Work account first, personal only when work is rate limited.
#
# A rate limit is per account, so exhausting one should not end the
# night - but failing over on the wrong signal would spend the reserve on
# an ordinary error, and failing over on none would waste the reserve
# entirely. Both directions are checked here.
set -uo pipefail
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

export CLAUDE_TOKEN_DIR="$tmp/secrets"
mkdir -p "$CLAUDE_TOKEN_DIR"
printf 'work-token' > "$CLAUDE_TOKEN_DIR/oauth-token"
printf 'personal-token' > "$CLAUDE_TOKEN_DIR/oauth-token-personal"

# shellcheck disable=SC1091
NIGHTLY_NS=test . "$(dirname "${BASH_SOURCE[0]}")/../lib/pod-common.sh" 2>/dev/null

# --- the rate-limit signal -------------------------------------------
for text in \
  'desloppify_run outcome=BLOCKED stop_reason=api_error_429' \
  '{"status": 429}' \
  'Error: rate limit exceeded' \
  'You have hit your usage limit' \
  "You've hit your 5-hour limit · resets 10:10pm (UTC)" \
  'You have hit your 7-hour limit' \
  '{"terminal_reason":"limit_reached"}' \
  '{"subtype": "quota_exceeded"}' \
  '{"api_error_status": 429}' \
  'limit_reached' \
  'quota_exceeded' \
  'insufficient_credits'
do
  claude_rate_limited "$text" || { echo "FAIL: missed a rate limit in: $text"; fail=1; }
done

# Must NOT match: the pattern was widened to catch the CLI's "N-hour
# limit" wording, and a pattern that also eats ordinary build output
# would send every failure to the personal account.
for text in \
  'compilation failed' \
  'test failure in pkg/foo' \
  'the 5-hour build limit was discussed in the PR' \
  '{"terminal_reason":"completed"}' \
  '{"api_error_status": null}' \
  'cache limit · resets on deploy' \
  'docs say the limit resets daily' \
  'ERROR: connection limit  resets after timeout' \
  'test: shows banner when you hit your 5-hour limit' \
  'feat(billing): warn before users hit your 24-hour limit' \
  'completed' \
  'max_turns'
do
  claude_rate_limited "$text" && { echo "FAIL: false positive on: $text"; fail=1; }
done

# ...and what must NOT trigger it, or an ordinary failure burns the reserve.
for text in \
  'stop_reason=timeout' \
  'FATAL: desloppify is not on PATH' \
  'error: pathspec did not match' \
  'tools_denied=4'
do
  claude_rate_limited "$text" && { echo "FAIL: treated as a rate limit: $text"; fail=1; }
done

# --- account selection ------------------------------------------------
use_claude_account work || { echo "FAIL: work account not selectable"; fail=1; }
[ "$CLAUDE_CODE_OAUTH_TOKEN" = "work-token" ] || { echo "FAIL: wrong token for work"; fail=1; }
use_claude_account personal || { echo "FAIL: personal not selectable"; fail=1; }
[ "$CLAUDE_CODE_OAUTH_TOKEN" = "personal-token" ] || { echo "FAIL: wrong token for personal"; fail=1; }

# An API key must never survive selection: it outranks the OAuth token.
export ANTHROPIC_API_KEY=leaked
use_claude_account work
[ -z "${ANTHROPIC_API_KEY:-}" ] || { echo "FAIL: ANTHROPIC_API_KEY survived"; fail=1; }

# --- failover ---------------------------------------------------------
attempt_log="$tmp/attempts"

: > "$attempt_log"
ratelimited_cmd() { echo "$CLAUDE_ACCOUNT" >> "$attempt_log"; echo "stop_reason=api_error_429"; return 1; }
run_with_account_failover ratelimited_cmd >/dev/null 2>&1
[ "$(wc -l < "$attempt_log")" -eq 2 ] || { echo "FAIL: a rate limit did not retry"; fail=1; }
[ "$(head -1 "$attempt_log")" = "work" ] || { echo "FAIL: did not try work first"; fail=1; }
[ "$(tail -1 "$attempt_log")" = "personal" ] || { echo "FAIL: did not fail over to personal"; fail=1; }

: > "$attempt_log"
other_failure() { echo "$CLAUDE_ACCOUNT" >> "$attempt_log"; echo "stop_reason=timeout"; return 1; }
run_with_account_failover other_failure >/dev/null 2>&1
[ "$(wc -l < "$attempt_log")" -eq 1 ] || { echo "FAIL: a non-rate-limit failure burned the reserve"; fail=1; }

: > "$attempt_log"
ok_cmd() { echo "$CLAUDE_ACCOUNT" >> "$attempt_log"; return 0; }
run_with_account_failover ok_cmd >/dev/null 2>&1
[ "$(wc -l < "$attempt_log")" -eq 1 ] || { echo "FAIL: a success was retried"; fail=1; }

# --- missing tokens ----------------------------------------------------
rm -f "$CLAUDE_TOKEN_DIR/oauth-token"
: > "$attempt_log"
run_with_account_failover ok_cmd >/dev/null 2>&1
[ "$(cat "$attempt_log")" = "personal" ] || { echo "FAIL: no work token should fall straight to personal"; fail=1; }

rm -f "$CLAUDE_TOKEN_DIR/oauth-token-personal"

# A pod with no mounted token must still pass if the CLI has its own
# login. The session pods authenticate that way and have no
# /run/secrets/claude mount; refusing them would stop all three stages
# that work today, which is what this guards against.
export HOME="$tmp/home"
mkdir -p "$HOME/.claude"
printf '{"claudeAiOauth":{}}' > "$HOME/.claude/.credentials.json"
preflight_credential >/dev/null 2>&1 || { echo "FAIL: refused a pod that has the CLI's own login"; fail=1; }

rm -f "$HOME/.claude/.credentials.json"
preflight_credential >/dev/null 2>&1 && { echo "FAIL: passed with no tokens and no CLI login"; fail=1; }

# --- the message the CLI actually prints ----------------------------------
# The pattern matched only "[0-9]+-hour limit", and on 2026-11-14 the CLI
# said "You've hit your weekly limit · resets Nov 16, 11am (UTC)". The
# detection missed it, so the stage saw a bare non-zero exit, found no PR,
# and parked the card - with a personal token mounted and unused. Pinning
# the real strings here rather than a paraphrase: the whole failure was
# the gap between what the pattern expected and what the CLI said.
for msg in \
  "You've hit your weekly limit · resets Nov 16, 11am (UTC)" \
  "You've hit your 5-hour limit · resets 3pm" \
  "You've hit your daily limit" \
  "You've hit your monthly limit"; do
  claude_rate_limited "$msg" \
    || { echo "FAIL: not detected as a limit: $msg"; fail=1; }
done

# And the other direction. A loose pattern here is worse than a tight one:
# it burns the personal account on runs that were never limited.
for msg in \
  "the docs say the limit resets daily" \
  "error: compilation failed" \
  "FAIL: 3 assertions failed" \
  "weekly report generated"; do
  claude_rate_limited "$msg" \
    && { echo "FAIL: false positive, would switch accounts: $msg"; fail=1; }
done

# --- the stages must actually CALL the wrapper ----------------------------
# This suite passed for weeks while all three stages invoked `claude -p`
# bare, because it only ever exercised the helper directly. A green run
# here plus a mounted personal token looked exactly like working failover.
# lib/claude-account.sh said as much in prose ("Do not read this as the
# stages being covered"); prose does not fail a build.
here_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for stage in stage-author stage-test stage-merge; do
  f="$here_dir/../$stage.sh"
  [ -f "$f" ] || { echo "FAIL: cannot find $stage.sh to check"; fail=1; continue; }
  grep -q 'run_with_account_failover' "$f" \
    || { echo "FAIL: $stage.sh does not call run_with_account_failover"; fail=1; }
  # A bare `claude -p` left anywhere in the stage is the bug returning.
  # CODE lines only: these scripts discuss `claude -p` in their comments,
  # including the comment explaining this very wiring, and matching those
  # fails on the explanation rather than the behaviour.
  while IFS=: read -r n _; do
    prev=$(sed -n "$((n - 1))p" "$f")
    case "$prev" in *run_with_account_failover*) continue ;; esac
    echo "FAIL: $stage.sh line $n invokes claude -p outside the wrapper"
    fail=1
  done < <(grep -nE '(^|[^_[:alnum:]])claude -p' "$f" | grep -v ':[[:space:]]*#')
done

[ "$fail" -eq 0 ] && echo "PASS - work first, personal on a rate limit only, no key leak, CLI login honoured, nothing-at-all refused, real limit messages detected, and all three stages call the wrapper"
exit "$fail"
