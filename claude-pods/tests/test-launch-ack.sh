#!/usr/bin/env bash
# Acceptance must follow lock acquisition, and an expired launch must stop.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/pod-common.sh"

# A 202 from the old dispatcher, a failed command or mismatched acknowledgment
# must never grant permission to work. No cluster or actual HTTP call.
require_dispatch_command task1 owner/repo command1
export DISPATCH_API_KEY=test
COMMAND_DIGEST=test-digest
curl() { printf '%s\n%s' "$fixture_reply" "$fixture_code"; }
fixture_reply='{"version":1,"accepted":true,"task":"task1","command":"command1","event":"author-started"}'
fixture_code=200
kaneo_work_started task1 stage-author
for fixture_code in 202 409 500; do
  if kaneo_work_started task1 stage-author 2>/dev/null; then
    echo "HTTP $fixture_code granted permission" >&2; exit 1
  fi
done
fixture_code=200
fixture_reply='{"version":1,"accepted":true,"task":"task1","command":"other","event":"author-started"}'
if kaneo_work_started task1 stage-author 2>/dev/null; then
  echo 'wrong command granted permission' >&2; exit 1
fi
if require_dispatch_command task1 owner/repo 2>/dev/null; then
  echo 'uncommanded worker accepted' >&2; exit 1
fi
echo 'PASS: command-scoped start acknowledgment'
# Failed rework accounting must not permit an uncounted retry loop.
outcome_called=false
kaneo_note() { return 1; }
kaneo_outcome() { outcome_called=true; }
if kaneo_requeue task1 reason 2>/dev/null; then
  echo 'requeued without its rework receipt' >&2; exit 1
fi
[ "$outcome_called" = false ]

# A no-PR author result must reach the card before the terminal report.
(
  GH_TOKEN=secret_test_token
  note="" outcome=""
  kaneo_note() { note="$2"; }
  kaneo_outcome() { [ -n "$note" ]; outcome="$2"; }
  report_author_no_pr task1 'OBSOLETE: the endpoint was removed. secret_test_token'
  [[ "$note" == *'OBSOLETE: the endpoint was removed.'* ]]
  [[ "$note" != *secret_test_token* ]]
  [ "$outcome" = failed ]
  report_author_no_pr task1 "$(printf '%07000d' 0)"
  [[ "$note" == *'[truncated; full report in worker log]'* ]]
  [ "${#note}" -lt 6500 ]
  outcome=""
  kaneo_note() { return 1; }
  if report_author_no_pr task1 'SKIPPED: missing credentials'; then
    echo 'author failure accepted without its explanation' >&2; exit 1
  fi
  [ -z "$outcome" ]
)

command -v flock >/dev/null || { echo 'SKIP: flock requires Linux'; exit 0; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export NIGHTLY_LOCK="$tmp/lock"
export NIGHTLY_LAUNCH_ACK="$tmp/ack"
(
  take_pod_lock
  test "$(cat "$NIGHTLY_LAUNCH_ACK")" = accepted
  # Independent descriptor: a second worker must acknowledge contention.
  (
    exec 9>&-
    NIGHTLY_LAUNCH_ACK="$tmp/busy"
    if take_pod_lock; then echo 'second worker acquired occupied lock' >&2; exit 1; fi
    test "$(cat "$NIGHTLY_LAUNCH_ACK")" = busy
  )
)
(
  NIGHTLY_LAUNCH_ACK="$tmp/expired/ack"
  if take_pod_lock 2>/dev/null; then echo 'worker accepted an expired launch' >&2; exit 1; fi
)
# Existing/manual launch callers do not participate in the handshake.
(unset NIGHTLY_LAUNCH_ACK; take_pod_lock)
echo 'PASS: worker launch acknowledgment'
