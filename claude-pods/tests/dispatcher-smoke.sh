#!/usr/bin/env bash
# Starts the dispatcher for real and exercises its entry points.
#
# `node --check` only parses: it cannot see that spawnSync is called but
# never imported, because that is a runtime ReferenceError. That exact bug
# shipped and broke every dispatch with "spawnSync is not defined" — the
# file was syntactically perfect.
#
# So this boots the server, posts a signed webhook, and fails if the
# handler throws. It needs no cluster: the payload names a column that
# routes nowhere, so nothing is ever executed.
set -uo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
printf 'testsecret' > "$tmp/webhook-secret"
printf 'testkey'    > "$tmp/api-key"

# A stub Kaneo, so the dispatching path gets past the label lookup and
# reaches the code that only runs on a real dispatch — the pod busy check
# and podWorksRepo. Without it the fetch fails first and everything after
# is never executed, which is how a missing import shipped: the test
# passed because it never got that far.
node -e '
const {createServer} = require("node:http");
createServer((req,res)=>{
  res.writeHead(200,{"content-type":"application/json"});
  res.end(JSON.stringify([{name:"repo:testrepo"}]));
}).listen(18081);
' & stub=$!
trap 'rm -rf "$tmp"; kill ${pid:-0} ${stub:-0} 2>/dev/null' EXIT

PORT=18080 \
DISPATCH_SECRET_FILE="$tmp/webhook-secret" \
DISPATCH_API_KEY_FILE="$tmp/api-key" \
KANEO_API_URL="http://127.0.0.1:18081" \
NIGHTLY_OWNER="TestOwner" \
  node dispatcher/dispatch.mjs > "$tmp/log" 2>&1 &
pid=$!

for _ in $(seq 1 40); do
  curl -fsS -o /dev/null "http://127.0.0.1:18080/healthz" 2>/dev/null && break
  sleep 0.25
done
curl -fsS -o /dev/null "http://127.0.0.1:18080/healthz" 2>/dev/null || {
  echo "FAIL: dispatcher did not start"; sed -n '1,20p' "$tmp/log"; exit 1; }

# An unsigned POST must be refused.
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -d '{}' "http://127.0.0.1:18080/")
[ "$code" = "401" ] || { echo "FAIL: unsigned POST got $code, want 401"; exit 1; }

post() { # body -> http code
  local body="$1" sig
  sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac testsecret -hex | awk '{print $NF}')
  curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H "X-Kaneo-Signature: $sig" --data-binary "$body" "http://127.0.0.1:18080/"
}

# An inert column: verify + parse + routing.
code=$(post '{"event":"task.status_changed","task":{"id":"t1","ticketId":"T-1"},"data":{"newStatus":"backlog"}}')
[ "$code" = "202" ] || { echo "FAIL: signed POST got $code, want 202"; exit 1; }

# A DISPATCHING column. This is the one that matters: it walks the whole
# path — label lookup, the pod busy check, podWorksRepo — which is where
# the code that only runs on a real dispatch lives. An inert column
# returns before any of it, so a test that only sends `backlog` passes
# happily against a dispatcher that cannot dispatch at all.
#
# No cluster is needed: the Kaneo lookup fails (nothing is listening on
# the API URL) and the handler must report that cleanly rather than throw.
code=$(post '{"event":"task.status_changed","task":{"id":"t2","ticketId":"T-2"},"data":{"newStatus":"to-do"}}')
[ "$code" = "202" ] || { echo "FAIL: dispatching column got $code, want 202"; exit 1; }

sleep 3
if grep -qiE "ReferenceError|is not defined|TypeError" "$tmp/log"; then
  echo "FAIL: dispatcher threw at runtime:"
  grep -iE "ReferenceError|is not defined|TypeError" "$tmp/log" | head -3
  exit 1
fi
grep -q "noop" "$tmp/log" || { echo "FAIL: inert column was not logged"; sed -n '1,20p' "$tmp/log"; exit 1; }
# The dispatching path must have reached the launch. START is logged only
# after the label lookup, the busy check and podWorksRepo have all run, so
# this one line is what proves that code executed rather than throwing.
#
# (kubectl is absent or points nowhere here, so the launch itself fails —
# that is fine and expected. What is being tested is that the dispatcher
# got that far.)
# Either outcome proves the path executed: START means it launched, BUSY
# means podIsBusy ran and reported the pod unavailable. Both require the
# label lookup, podWorksRepo and the busy check to have run without
# throwing, which is the whole point.
#
# BUSY is what happens here, because kubectl cannot reach a cluster from a
# test runner and a failed busy check is deliberately read as "busy" —
# starting a second agent beside a live one is the failure that guard
# exists to prevent. Asserting on only START would make this test demand a
# cluster it does not need.
grep -qE "(START|BUSY).*T-2" "$tmp/log" || {
  echo "FAIL: dispatching path never reached the pod check"; sed -n '1,25p' "$tmp/log"; exit 1; }

echo "PASS: dispatcher starts, refuses unsigned posts, routes an inert column, and walks the dispatching path without throwing"
