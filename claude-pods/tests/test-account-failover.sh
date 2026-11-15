#!/usr/bin/env bash
# Work account first, personal only when work is out of quota.
#
# A quota is per account, so exhausting one should not end the night -
# but failing over on the wrong signal spends the reserve on an ordinary
# error, and failing over on none wastes it entirely. Both directions
# are checked.
#
# Detection reads the CLI's JSON (terminal_reason / subtype /
# stop_reason / api_error_status), never the agent's prose. There are
# therefore no CLI message strings pinned in this file: an earlier
# version scraped those sentences and needed 23 of them, each one a
# shape someone had to discover.
set -uo pipefail
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
here_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export CLAUDE_TOKEN_DIR="$tmp/secrets"
mkdir -p "$CLAUDE_TOKEN_DIR"
printf 'work-token' > "$CLAUDE_TOKEN_DIR/oauth-token"
printf 'personal-token' > "$CLAUDE_TOKEN_DIR/oauth-token-personal"

# shellcheck disable=SC1091
NIGHTLY_NS=test . "$here_dir/../lib/pod-common.sh" 2>/dev/null

# --- what counts as out of quota -------------------------------------
for text in \
  'limit_reached' \
  'quota_exceeded' \
  'insufficient_credits' \
  'api_error_429' \
  '{"terminal_reason":"limit_reached"}' \
  '{"subtype":"quota_exceeded"}' \
  '{"stop_reason":"usage_limit_reached"}' \
  '{"api_error_status":429,"terminal_reason":"api_error"}'
do
  claude_rate_limited "$text" || { echo "FAIL: missed a limit in: $text"; fail=1; }
done

# On an error the CLI prints a diagnostic line before the JSON object,
# so the object has to be read from the last line rather than the whole
# capture. Verified with `claude -p --output-format json --model
# no-such-model`, which prints "[claude-code:unrecognized_model] {...}"
# and then the result object.
claude_rate_limited '[claude-code:unrecognized_model] {"model":"x"}
{"terminal_reason":"limit_reached"}' \
  || { echo "FAIL: a limit behind a diagnostic line was missed"; fail=1; }

# Not out of quota: ordinary outcomes, other HTTP errors, and the
# agent's own words. The prose lives in .result, which the detector
# never reads - that is the point of reading JSON at all. Before this,
# a ticket that merely edited a file named rate_limit.go could spend a
# second full agent run on the reserve account.
for text in \
  'completed' \
  'timeout' \
  'max_turns' \
  '{"terminal_reason":"completed","is_error":false}' \
  '{"terminal_reason":"api_error","api_error_status":404}' \
  '{"terminal_reason":"api_error","api_error_status":500}' \
  '{"terminal_reason":"max_turns"}' \
  '{"terminal_reason":"completed","result":"I edited rate_limit.go and asserted on 429 responses"}' \
  '{"terminal_reason":"completed","result":"You have hit your weekly limit is the string we match"}'
do
  claude_rate_limited "$text" && { echo "FAIL: not a limit, read as one: $text"; fail=1; }
done

# --- the reason list has one home ------------------------------------
# $CLAUDE_LIMIT_REASONS is the single home, and these two gates keep it
# honest in both directions. One mechanism cannot do it: a loop that
# derives its cases from the variable cannot notice a token being
# DELETED, because deleting it also shrinks the loop. That was not
# hypothetical - with a derived-only loop, dropping rate_limit,
# out_of_credits or credit_balance_too_low left this suite green, and
# rate_limit was the token the fix that created the variable was written
# to rescue.
#
# One line: a newline in this string breaks the `case` matches below.
REQUIRED_REASONS="limit_reached quota_exceeded rate_limited rate_limit usage_limit_reached insufficient_credits credit_balance_too_low out_of_credits"

for tok in $REQUIRED_REASONS api_error_429; do
  claude_rate_limited "$tok" \
    || { echo "FAIL: reason not detected bare: $tok"; fail=1; }
  claude_rate_limited "{\"terminal_reason\":\"$tok\"}" \
    || { echo "FAIL: reason not detected in JSON: $tok"; fail=1; }
done

for tok in $REQUIRED_REASONS; do
  case "|$CLAUDE_LIMIT_REASONS|" in
    *"|$tok|"*) ;;
    *) echo "FAIL: '$tok' was removed from CLAUDE_LIMIT_REASONS"; fail=1 ;;
  esac
done
for tok in $(printf '%s' "$CLAUDE_LIMIT_REASONS" | tr '|' ' '); do
  case " $REQUIRED_REASONS " in
    *" $tok "*) ;;
    *) echo "FAIL: CLAUDE_LIMIT_REASONS has '$tok', which this suite does not pin"
       fail=1 ;;
  esac
done

# --- the agent's prose is still readable -----------------------------
# stage-merge greps a VERDICT line out of the output, so .result has to
# survive the round trip intact, newlines and all.
got=$(claude_result_text '{"result":"ANALYSIS: fine\n\nVERDICT: MERGE","terminal_reason":"completed"}')
[ "$(printf '%s' "$got" | grep -oE '^VERDICT: (MERGE|NO-MERGE|RISKY)' | tail -1 | awk '{print $2}')" = "MERGE" ] \
  || { echo "FAIL: the VERDICT line did not survive .result extraction"; fail=1; }

# Non-JSON passes through, so a run that died before emitting a result
# object still logs whatever it did print.
[ "$(claude_result_text 'plain text, no json')" = "plain text, no json" ] \
  || { echo "FAIL: non-JSON output was not passed through"; fail=1; }

# --- account selection -----------------------------------------------
use_claude_account work || { echo "FAIL: work account not selectable"; fail=1; }
[ "$CLAUDE_CODE_OAUTH_TOKEN" = "work-token" ] || { echo "FAIL: wrong token for work"; fail=1; }
use_claude_account personal || { echo "FAIL: personal not selectable"; fail=1; }
[ "$CLAUDE_CODE_OAUTH_TOKEN" = "personal-token" ] || { echo "FAIL: wrong token for personal"; fail=1; }

# An API key must never survive selection: either key silently outranks
# the OAuth token and bills per token against the API account.
export ANTHROPIC_API_KEY=leaked
use_claude_account work
[ -z "${ANTHROPIC_API_KEY:-}" ] || { echo "FAIL: ANTHROPIC_API_KEY survived"; fail=1; }

# --- failover --------------------------------------------------------
attempt_log="$tmp/attempts"

: > "$attempt_log"
limited_cmd() { echo "$CLAUDE_ACCOUNT" >> "$attempt_log"; echo '{"terminal_reason":"limit_reached"}'; return 1; }
run_with_account_failover limited_cmd >/dev/null 2>&1
[ "$(wc -l < "$attempt_log")" -eq 2 ] || { echo "FAIL: a limit did not retry"; fail=1; }
[ "$(head -1 "$attempt_log")" = "work" ] || { echo "FAIL: did not try work first"; fail=1; }
[ "$(tail -1 "$attempt_log")" = "personal" ] || { echo "FAIL: did not fail over to personal"; fail=1; }

: > "$attempt_log"
other_failure() { echo "$CLAUDE_ACCOUNT" >> "$attempt_log"; echo '{"terminal_reason":"api_error","api_error_status":500}'; return 1; }
run_with_account_failover other_failure >/dev/null 2>&1
[ "$(wc -l < "$attempt_log")" -eq 1 ] || { echo "FAIL: a non-limit failure burned the reserve"; fail=1; }

: > "$attempt_log"
ok_cmd() { echo "$CLAUDE_ACCOUNT" >> "$attempt_log"; echo '{"terminal_reason":"completed"}'; }
run_with_account_failover ok_cmd >/dev/null 2>&1
[ "$(wc -l < "$attempt_log")" -eq 1 ] || { echo "FAIL: a success was retried"; fail=1; }

# `timeout` killing a wedged run is not an exhausted account. Both the
# stages and the wrapper treat 124 as its own thing; without the
# exclusion a wedged run earns a second full timeout on the reserve.
: > "$attempt_log"
timed_out() { echo "$CLAUDE_ACCOUNT" >> "$attempt_log"; echo '{"terminal_reason":"limit_reached"}'; return 124; }
run_with_account_failover timed_out >/dev/null 2>&1
[ "$(wc -l < "$attempt_log")" -eq 1 ] || { echo "FAIL: a timeout burned the reserve"; fail=1; }

# --- the prompt must survive the retry -------------------------------
# The retry has to see the SAME prompt as the first attempt. It did not:
# every stage wrote `out=$(run_with_account_failover ... < prompt.txt)`,
# which attaches the redirect to the whole function, so attempt 1 read
# stdin to EOF and attempt 2 ran the agent with ZERO BYTES. The failover
# fired, spent the reserve on an empty prompt, and would have parked the
# card anyway.
#
# The fake READS STDIN, which is the point: this suite missed the bug
# because none of its fakes did. It reads with `read -t` rather than
# `cat` because an unbounded read blocks on the runner's own stdin if
# the wrapper stops redirecting, and the suite then HANGS instead of
# failing - a hang reports nothing in CI.
prompt_file="$tmp/prompt.txt"
printf 'ticket ABC-123\nimplement the thing\n' > "$prompt_file"
# Counted the way the fake reads it (line bodies, no separators), so the
# expectation is derived from the fixture rather than written down.
want_bytes=$(awk '{ n += length($0) } END { print n+0 }' "$prompt_file")

stdin_reader() {
  local p="" line
  while IFS= read -r -t 5 line; do p="$p$line"; done
  printf '%s %s\n' "$CLAUDE_ACCOUNT" "${#p}" >> "$attempt_log"
  [ "$CLAUDE_ACCOUNT" = "work" ] && { echo '{"terminal_reason":"limit_reached"}'; return 1; }
  echo '{"terminal_reason":"completed"}'
}

: > "$attempt_log"
run_with_account_failover --stdin "$prompt_file" stdin_reader >/dev/null 2>&1
[ "$(wc -l < "$attempt_log")" -eq 2 ] \
  || { echo "FAIL: --stdin did not retry on a limit"; fail=1; }
while read -r acct bytes; do
  [ "$bytes" = "$want_bytes" ] \
    || { echo "FAIL: the $acct attempt got $bytes prompt bytes, want $want_bytes"; fail=1; }
done < "$attempt_log"

# --- missing tokens --------------------------------------------------
rm -f "$CLAUDE_TOKEN_DIR/oauth-token"
: > "$attempt_log"
run_with_account_failover ok_cmd >/dev/null 2>&1
[ "$(cat "$attempt_log")" = "personal" ] || { echo "FAIL: no work token should fall straight to personal"; fail=1; }

rm -f "$CLAUDE_TOKEN_DIR/oauth-token-personal"

# A pod with no mounted token must still pass if the CLI has its own
# login. The session pods authenticate that way and have no
# /run/secrets/claude mount; refusing them would stop all three stages.
export HOME="$tmp/home"
mkdir -p "$HOME/.claude"
printf '{"claudeAiOauth":{}}' > "$HOME/.claude/.credentials.json"
preflight_credential >/dev/null 2>&1 || { echo "FAIL: refused a pod that has the CLI's own login"; fail=1; }

rm -f "$HOME/.claude/.credentials.json"
preflight_credential >/dev/null 2>&1 && { echo "FAIL: passed with no tokens and no CLI login"; fail=1; }

# --- every stage must go through the wrapper -------------------------
# This suite passed for weeks while all three stages invoked `claude -p`
# bare, because it only ever exercised the helper directly. The library
# said as much in prose, and prose does not fail a build.
#
# Checked on the LOGICAL command - comments stripped, backslash
# continuations joined - because an earlier version checked line
# adjacency and certified an unwired stage.
for stage in stage-author stage-test stage-merge; do
  f="$here_dir/../$stage.sh"
  [ -f "$f" ] || { echo "FAIL: cannot find $stage.sh to check"; fail=1; continue; }
  # Join backslash continuations, then strip comments. The previous
  # form of this (tr to \001, sed, tr back) did NOT join anything - the
  # substitution never matched - so a gate documented as checking the
  # logical command was still matching line adjacency, the very defect
  # it was written to replace. Verified by hand on a three-line
  # continuation before and after.
  joined=$(sed -e :a -e '/\\$/N; s/\\\n//; ta' "$f" | sed 's/#.*//')

  printf '%s' "$joined" | grep -q 'run_with_account_failover' \
    || { echo "FAIL: $stage.sh does not call run_with_account_failover"; fail=1; }

  # A bare `claude -p` anywhere in the stage is the bug returning.
  printf '%s' "$joined" | grep -E 'claude -p' | grep -qv 'run_with_account_failover' \
    && { echo "FAIL: $stage.sh invokes claude -p outside the wrapper"; fail=1; }

  # The prompt goes through --stdin. A redirect around the wrapper is
  # the drained-stdin bug, and it is invisible in a diff that still
  # shows a prompt file being passed.
  printf '%s' "$joined" | grep -qE 'run_with_account_failover[^|&;]*<[[:space:]]*"?\$' \
    && { echo "FAIL: $stage.sh redirects into run_with_account_failover; pass --stdin"; fail=1; }
  printf '%s' "$joined" | grep -q 'run_with_account_failover --stdin' \
    || { echo "FAIL: $stage.sh does not pass its prompt with --stdin"; fail=1; }

  # Detection needs the JSON, so every stage has to ask for it.
  printf '%s' "$joined" | grep -q 'output-format json' \
    || { echo "FAIL: $stage.sh does not pass --output-format json"; fail=1; }
done

# --- desloppify shares this library ----------------------------------
# The desloppify image COPYs lib/claude-account.sh, and
# nightly-desloppify.sh calls the detector with a BARE reason word from
# `jq -r .stop_reason`. Pinned in both directions because a change made
# for the stages has to keep that caller working.
for r in $REQUIRED_REASONS api_error_429; do
  claude_rate_limited "$r" \
    || { echo "FAIL: desloppify would not fail over on stop_reason=$r"; fail=1; }
done
for r in completed timeout max_turns budget no_result error api_error_500; do
  claude_rate_limited "$r" \
    && { echo "FAIL: desloppify would fail over on stop_reason=$r"; fail=1; }
done

[ "$fail" -eq 0 ] && echo "PASS - work first, personal only when out of quota, no key leak, CLI login honoured, nothing-at-all refused, prompt survives the retry, and all three stages go through the wrapper with JSON output"
exit "$fail"
