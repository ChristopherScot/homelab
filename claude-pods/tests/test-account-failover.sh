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
  'You have hit your usage limit'
do
  claude_rate_limited "$text" || { echo "FAIL: missed a rate limit in: $text"; fail=1; }
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
# /run/secrets/claude mount; refusing them would stop three nightly jobs
# that work today, which is what this guards against.
export HOME="$tmp/home"
mkdir -p "$HOME/.claude"
printf '{"claudeAiOauth":{}}' > "$HOME/.claude/.credentials.json"
preflight_credential >/dev/null 2>&1 || { echo "FAIL: refused a pod that has the CLI's own login"; fail=1; }

rm -f "$HOME/.claude/.credentials.json"
preflight_credential >/dev/null 2>&1 && { echo "FAIL: passed with no tokens and no CLI login"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS - work first, personal on a rate limit only, no key leak, CLI login honoured, nothing-at-all refused"
exit "$fail"
