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

# A bare `{"status": 429}` is deliberately NOT a limit signal, and this
# is the assertion that used to say it was. Nothing emits it: the
# 2.1.323 binary contains zero occurrences of `"status": 429` (its only
# quoted-key 429 is `"headline":"429`), and every genuine 429 from the
# CLI arrives as `"api_error_status": 429`, which IS matched above. What
# does produce that string is an agent writing a 429 test fixture -
# these stages edit this repository - so matching it only ever cost a
# reserve run on a run that was never limited.
for text in \
  '{"status": 429}' \
  '{"status":429,"body":"slow down"}' \
  'Added testdata/429.json with {"status": 429}'
do
  claude_rate_limited "$text" && { echo "FAIL: a 429 fixture read as a limit: $text"; fail=1; }
done

# api_error_429 is matched only as a field value, never as a loose word,
# for the same reason. Both real producers write it as one:
# nightly-desloppify.sh:383 passes a bare `jq -r .stop_reason`, and
# :400 logs `stop_reason=api_error_429`.
claude_rate_limited 'api_error_429' \
  || { echo "FAIL: a bare terminal reason is not detected"; fail=1; }
claude_rate_limited 'added handling for api_error_429 in run.py' \
  && { echo "FAIL: api_error_429 mentioned in prose read as a limit"; fail=1; }

# Every exhaustion message the 2.1.323 binary can actually compose.
# Not invented shapes: the CLI's own predicate is
#
#   gvs.some(n => e.startsWith(n)) || /^(Fable|Haiku|Mythos|Opus|
#     Sonnet)(?: [^\u00B7\n]{1,40})? requires usage credits\./.test(e)
#
# where gvs is a 12-entry literal array, and the "hit your" line is
# built by `You've hit your ${label}${suffix}` over 14 labels. These
# are those strings. The point of listing them is that the detector was
# twice written against a guess at the wording - first [0-9]+-hour,
# then weekly|daily|monthly - and a guess is what let the 2026-11-14
# weekly limit through with a personal token mounted and unused.
for text in \
  "You've hit your limit" \
  "You've hit your session limit" \
  "You've hit your weekly limit \xc2\xb7 resets Nov 16, 11am (UTC)" \
  "You've hit your weekly limit \xc2\xb7 progress saved" \
  "You've hit your Fable limit" \
  "You've hit your Opus limit \xc2\xb7 ask your admin to raise it" \
  "You've hit your monthly spend limit" \
  "You've hit your team's monthly spend limit" \
  "You've hit your channel's monthly spend limit" \
  "You've hit your org's monthly usage limit" \
  "You've hit your usage credit limit" \
  "You've hit your 5-hour limit \xc2\xb7 resets 3pm" \
  "You've reached your weekly limit" \
  "You're out of usage credits" \
  "You're out of usage credits. Run /usage-credits to keep going" \
  "You're out of extra usage" \
  "Your org is out of usage \xc2\xb7 contact your admin" \
  "Your seat type doesn't include usage credits" \
  "Your usage allocation has been disabled by your admin" \
  "Your group's usage limit is set to \$0" \
  'Opus requires usage credits.' \
  "You've hit your team's shared budget. /model to switch models." \
  "You've hit your team's shared budget" \
  "Usage is paused for your organization. For help, please contact support." \
  "This service is disabled for your org" \
  'Fable 5 requires usage credits.' \
  'Fast mode requires usage credits'
do
  claude_rate_limited "$(printf '%b' "$text")" \
    || { echo "FAIL: a real CLI exhaustion message was missed: $text"; fail=1; }
done

# The failure mode that costs a human a round trip, rather than a
# reserve run: a stage that failed for an ordinary reason, whose output
# merely discusses limits. Every one of these is output a real stage
# produces - the stages review and edit THIS repository, including this
# file - and each was a false positive at some point in this fix.
while IFS= read -r case; do
  [ -n "$case" ] || continue
  claude_rate_limited "$(printf '%b' "$case" | tail -40)" \
    && { echo "FAIL: an ordinary failure would burn the reserve: $case"; fail=1; }
done <<'ORDINARY'
Working on the rate limiting ticket.\nAdded a leaky-bucket limiter.\nSummary: implemented rate limiting for /v1.
VERDICT: NO-MERGE\nReasons:\n- the rate limit handling is untested
Done editing.\nTotal cost: $0.42\nTotal duration: 3m12s
    retry_test.go:88: expected status 429, got 200\nFAIL	example.com/gw/retry	0.012s
ok	example.com/gw/auth	0.004s\nFAIL	example.com/gw/ratelimit	0.009s
Added the fixture:\n{"status": 429, "body": "slow down"}\nWrote testdata/429.json
I updated claude_rate_limited to also match api_error_429.\nThe pattern now covers "you have hit your weekly limit".
The CLI prints "You've hit your weekly limit" when exhausted.
I think you have hit your configured per-project eslint file count limit.
Note that once you have hit your retry budget for the upstream call, the limit
You have hit your configured per-project eslint file count limit.
    You're out of usage credits is the fixture string we assert on
expected: You're out of usage credits
ORDINARY

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

# --- the prompt must survive the retry ------------------------------
# The retry has to see the SAME prompt as the first attempt. It did not:
# every stage wrote `out=$(run_with_account_failover ... < prompt.txt)`,
# which attaches the redirect to the whole function, so attempt 1 read
# stdin to EOF and attempt 2 inherited a drained descriptor and ran the
# agent with ZERO BYTES. The failover fired, spent the reserve account
# on an empty prompt, and would have parked the 2026-11-14 card anyway -
# defeating the entire point of this wrapper on the one case it was
# written for.
#
# This suite could not see it because none of its fake commands read
# stdin - ratelimited_cmd, ok_cmd and fake_claude all ignore it, and
# fake_claude takes its transcript from an env var. So the fake here
# READS STDIN, which is the whole point of the case: a fake that cannot
# observe the input cannot pin the input contract.
prompt_file="$tmp/prompt.txt"
printf 'ticket ABC-123\nimplement the thing\n' > "$prompt_file"
# Count the prompt the same way the fake below reads it - line bodies
# only, no separators - so the expected number is derived from the file
# rather than written down. Asserting a literal here would have to be
# re-derived every time the fixture or the reader changes, and an
# off-by-one in the ASSERTION reads exactly like an off-by-one in the
# CODE, which is the confusion this avoids. What the case actually pins
# is that both attempts see the SAME bytes and that the bytes are not
# zero; the exact count is only the vehicle.
want_bytes=$(awk '{ n += length($0) } END { print n+0 }' "$prompt_file")
: > "$attempt_log"
# Reads stdin with a bound, never a bare `cat`. If the wrapper stops
# redirecting, an unbounded read blocks on the test runner's own stdin
# and the suite HANGS instead of failing - which is how a CI run reports
# nothing at all rather than a red build. Found by mutating the library
# to ignore --stdin: the suite wedged for two minutes. `read -t` turns
# that into an empty read, which the byte assertion below then fails on.
stdin_reading_cmd() {
  local p=""; local line
  while IFS= read -r -t 5 line; do p="$p$line"; done
  printf '%s %s\n' "$CLAUDE_ACCOUNT" "${#p}" >> "$attempt_log"
  [ "$CLAUDE_ACCOUNT" = "work" ] && { echo "You've hit your weekly limit"; return 1; }
  echo "ran"
}
run_with_account_failover --stdin "$prompt_file" stdin_reading_cmd >/dev/null 2>&1
[ "$(wc -l < "$attempt_log")" -eq 2 ] \
  || { echo "FAIL: --stdin did not retry on a limit"; fail=1; }
while read -r acct bytes; do
  [ "$bytes" = "$want_bytes" ] \
    || { echo "FAIL: the $acct attempt got $bytes prompt bytes, want $want_bytes"; fail=1; }
done < "$attempt_log"

# And the shape the stages must NOT use: a redirect around the function
# drains stdin, so the retry gets nothing. Pinned as the wrong shape so
# that reintroducing it fails here rather than in production.
: > "$attempt_log"
run_with_account_failover stdin_reading_cmd >/dev/null 2>&1 < "$prompt_file"
second=$(sed -n '2p' "$attempt_log" | awk '{print $2}')
[ "${second:-0}" = "0" ] \
  || { echo "NOTE: a redirect around the wrapper no longer drains stdin ($second bytes) - if that is deliberate, delete this case"; }



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
# Every one of these was pulled out of the CLI binary with `strings`,
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
#
# TWO gates, because drift and deletion are different failures and one
# mechanism cannot catch both.
#
# The required set is written out HERE, independently of the library.
# That is deliberate duplication: a loop that reads
# $CLAUDE_LIMIT_REASONS cannot notice a token being deleted from it,
# because deleting the token also shrinks the loop - the gate stops
# asking about exactly the thing that was removed. Verified: with a
# derived-only loop, dropping `rate_limit`, `out_of_credits` or
# `credit_balance_too_low` from the variable left the suite green.
# `rate_limit` is the token the commit that introduced the variable was
# written to rescue, so its gate had a hole shaped like its own fix.
#
# So: this list pins WHICH reasons must be exhaustion signals, and the
# cross-check below pins that the library knows no more than these -
# which is what catches an addition that nobody pinned.
# One line: a newline inside this string breaks the `case` matches
# below, which match on " $tok " and would see "...rate_limit\ninsufficient..."
# as one word. The gate caught that in itself on first run.
REQUIRED_REASONS="limit_reached quota_exceeded rate_limited rate_limit insufficient_credits credit_balance_too_low out_of_credits"
for tok in $REQUIRED_REASONS api_error_429; do
  claude_terminal_reason_limited "$tok" \
    || { echo "FAIL: structured reason not detected: $tok"; fail=1; }
  claude_terminal_reason_limited "{\"terminal_reason\":\"$tok\"}" \
    || { echo "FAIL: structured reason not detected in JSON: $tok"; fail=1; }
done
claude_terminal_reason_limited "completed" \
  && { echo "FAIL: 'completed' read as a limit"; fail=1; }

# The other direction: the library must not carry a reason this file has
# not pinned. Without this, adding a token to $CLAUDE_LIMIT_REASONS and
# pinning nothing would be invisible, and the list above would drift
# into a stale subset - which is how it got to five of seven.
for tok in $(printf '%s' "$CLAUDE_LIMIT_REASONS" | tr '|' ' '); do
  case " $REQUIRED_REASONS " in
    *" $tok "*) ;;
    *) echo "FAIL: CLAUDE_LIMIT_REASONS has '$tok', which this suite does not pin"
       echo "      add it to REQUIRED_REASONS above, with a shape in the loops"
       fail=1 ;;
  esac
done
for tok in $REQUIRED_REASONS; do
  case "|$CLAUDE_LIMIT_REASONS|" in
    *"|$tok|"*) ;;
    *) echo "FAIL: '$tok' was removed from CLAUDE_LIMIT_REASONS"
       fail=1 ;;
  esac
done

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
# Driven through the REAL wrapper, counting attempts. Hand-slicing the
# input before calling the helper - which an earlier version of this
# block did - tests nothing about the wrapper's own window, and would
# pass whatever that window were. That is the same defect this suite is
# here to catch, one layer up.
# Earlier cases delete these on purpose to exercise the no-token paths,
# so put them back before driving the wrapper.
printf 'work-token' > "$CLAUDE_TOKEN_DIR/oauth-token"
printf 'personal-token' > "$CLAUDE_TOKEN_DIR/oauth-token-personal"
rm -f "$HOME/.claude/.credentials.json" 2>/dev/null || true

transcript_attempts() {
  local out n
  : > "$tmp/attempts"
  FAKE_TRANSCRIPT="$1" run_with_account_failover fake_claude >/dev/null 2>&1
  wc -l < "$tmp/attempts" | tr -d ' '
}
fake_claude() { echo x >> "$tmp/attempts"; printf '%s\n' "$FAKE_TRANSCRIPT"; return 1; }

# A real limit is NOT always last: the CLI appends "· progress saved" to
# the line, and a -p run prints its own epilogue after. tail -2 missed
# this and never tried the reserve - the 2026-11-14 failure, reintroduced
# by its own fix.
n=$(transcript_attempts "Starting work on the ticket.
You've hit your weekly limit · resets Nov 16, 11am (UTC)
Session ended after 0 turns.
Total cost: \$0.00")
[ "$n" = 2 ] || { echo "FAIL: a real limit with an epilogue did not fail over (attempts=$n)"; fail=1; }

# And an ordinary run must not. prompts/test.md asks the agent to list
# the commands it ran, so a command line IS the expected last line - a
# go test against a ratelimit package, or a curl reporting 429, used to
# spend a second full run on the reserve account.
for t in "Wrote BLOCKED to the verdict file.
Ran: go test ./internal/ratelimit -run TestRateLimited" \
         "Comment posted.
Commands: curl -i localhost:8080/x  (got status: 429)" \
         "A 429 is retried twice; status 429 is not distinguished from 503.
VERDICT: RISKY" \
         "claude_rate_limited now matches 'you have hit your weekly limit'.
VERDICT: MERGE"; do
  n=$(transcript_attempts "$t")
  [ "$n" = 1 ] \
    || { echo "FAIL: an ordinary run burned the reserve account (attempts=$n): ${t##*$'\n'}"; fail=1; }
done

# --- desloppify shares this library ---------------------------------------
# The desloppify image COPYs claude-pods/lib/claude-account.sh (its
# Dockerfile says so: "one copy of the account logic"), and its runner
# does its own failover off run.py's stop_reason rather than through
# run_with_account_failover. So this file is load-bearing for two pods
# with different call shapes, and a change made for the stages has to
# keep working for a bare reason word.
#
# Every stop_reason run.py can emit, checked in both directions, because
# the cost is asymmetric: a missed exhaustion reason ends the night on
# one account with the other untouched, and a false one spends a second
# full run for nothing.
# Also derived: desloppify passes the bare word, so every reason in the
# single home has to work through its call shape too.
for r in $(printf '%s' "$CLAUDE_LIMIT_REASONS" | tr '|' ' ') api_error_429; do
  claude_rate_limited "$r" \
    || { echo "FAIL: desloppify would not fail over on stop_reason=$r"; fail=1; }
done
for r in completed timeout max_turns budget no_result error api_error_500; do
  claude_rate_limited "$r" \
    && { echo "FAIL: desloppify would fail over on stop_reason=$r"; fail=1; }
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

# No stage may go back to redirecting the wrapper itself: that is the
# bug above, and it is invisible in a diff that still shows a prompt
# file being passed. Checked on the logical command, like the wiring
# gate below.
for stage in stage-author stage-test stage-merge; do
  f="$here_dir/../$stage.sh"
  joined=$(sed 's/#.*//' "$f" | tr '\n' '\001' | sed 's/\\\001/ /g' | tr '\001' '\n')
  printf '%s' "$joined" | grep -qE 'run_with_account_failover[^|&;]*<[[:space:]]*"?\$' \
    && { echo "FAIL: $stage.sh redirects into run_with_account_failover; pass --stdin instead"; fail=1; }
  printf '%s' "$joined" | grep -qE 'run_with_account_failover --stdin' \
    || { echo "FAIL: $stage.sh does not pass its prompt with --stdin"; fail=1; }
done
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
