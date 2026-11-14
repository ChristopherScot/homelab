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
# Every one of these was pulled out of the 2.1.325 binary with `strings`,
# except the weekly one, which is what the CLI actually printed on
# 2026-11-14 and is assembled at runtime. Enumerating periods was the
# wrong shape twice: first [0-9]+-hour only, then
# weekly|daily|monthly - and "session", "fast", "monthly spend" and a
# bare "hit your limit" are all real.
for msg in \
  "You've hit your weekly limit · resets Nov 16, 11am (UTC)" \
  "You've hit your 5-hour limit · resets 3pm" \
  "You've hit your limit" \
  "You've hit your session limit" \
  "You've hit your fast limit" \
  "You've hit your Fable limit" \
  "You've hit your monthly limit" \
  "You've hit your monthly spend limit" \
  "You've hit your channel's monthly spend limit" \
  "You're out of usage credits. Switch to another model to continue." \
  "Opus requires usage credits."; do
  claude_rate_limited "$msg" \
    || { echo "FAIL: not detected as a limit: $msg"; fail=1; }
done

# The structured tokens are the signal that should matter, and they are
# checked before any prose. Pinned separately so a prose change cannot
# quietly become the only thing holding this up.
for tok in limit_reached quota_exceeded rate_limited out_of_credits api_error_429; do
  claude_terminal_reason_limited "$tok" \
    || { echo "FAIL: structured reason not detected: $tok"; fail=1; }
  claude_terminal_reason_limited "{\"terminal_reason\":\"$tok\"}" \
    || { echo "FAIL: structured reason not detected in JSON: $tok"; fail=1; }
done
claude_terminal_reason_limited "completed" \
  && { echo "FAIL: 'completed' read as a limit"; fail=1; }

# --- a mention of the concept is not a limit ------------------------------
# `rate.?limit` on its own matched the FILENAME rate_limit.go. Harmless
# while nothing called the detection; the moment the stages did, any
# ticket touching rate-limiting code spent a second full agent run on the
# reserve account every time its tests failed normally.
for msg in \
  "FAIL: 3 assertions failed in rate_limit_test.go" \
  "Reviewing internal/ratelimit/rate_limit.go for the retry policy" \
  "added a rate limiter with a 429 backoff test"; do
  claude_rate_limited "$msg" \
    && { echo "FAIL: a mention of rate limiting read as a limit: $msg"; fail=1; }
done

# --- the detection input must stay bounded -------------------------------
# run_with_account_failover captures an hour of agent prose with 2>&1 and
# feeds it to the detection. A real limit ENDS the run, so its message is
# last; an agent merely discussing limits prints a test result after. The
# wrapper must therefore test the tail, not the transcript - a stage that
# edits this very file would otherwise fail over on every ordinary
# failure.
discussing="the detection matches 'you have hit your weekly limit' exactly
Running the suite...
FAIL: 2 assertions failed"
claude_rate_limited "$(printf '%s' "$discussing" | tail -2)" \
  && { echo "FAIL: a transcript discussing limits read as a limit"; fail=1; }
real_last="Reviewing the retry policy.
You've hit your weekly limit · resets Nov 16, 11am (UTC)"
claude_rate_limited "$(printf '%s' "$real_last" | tail -2)" \
  || { echo "FAIL: a real limit at the end of a transcript was missed"; fail=1; }
# And the wrapper has to actually do that slicing.
wrapper_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/claude-account.sh"
sed 's/[[:space:]]*#.*$//' "$wrapper_src" \
  | grep -qE 'claude_rate_limited "\$\(printf .* \| tail -[0-9]+\)"' \
  || { echo "FAIL: run_with_account_failover detects on unbounded output"; fail=1; }

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
  #
  # Checked on the logical command, not on line adjacency. Looking at the
  # PRECEDING line was itself blind: unwiring the stage while leaving the
  # word `run_with_account_failover` in a comment one line above passed -
  # a green test certifying an unwired stage, which is the exact defect
  # this suite exists to catch.
  #
  # So: strip comments, join backslash continuations into one line each,
  # then require every line that invokes `claude -p` to name the wrapper
  # on that same joined line. Comments are stripped first because these
  # scripts discuss `claude -p` in prose, including the comment
  # explaining this wiring.
  bare=$(sed 's/[[:space:]]*#.*$//' "$f" \
         | sed -e :a -e '/\\$/N; s/\\\n//; ta' \
         | grep -nE '(^|[^_[:alnum:]])claude -p' \
         | grep -v 'run_with_account_failover' || true)
  if [ -n "$bare" ]; then
    echo "FAIL: $stage.sh invokes claude -p outside the wrapper:"
    printf '  %s\n' "$bare" | head -3
    fail=1
  fi
done

[ "$fail" -eq 0 ] && echo "PASS - work first, personal on a rate limit only, no key leak, CLI login honoured, nothing-at-all refused, real limit messages detected, and all three stages call the wrapper"
exit "$fail"
