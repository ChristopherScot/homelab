#!/usr/bin/env bash
# bootstrap/garage-init.sh's control flow, driven against a fake kubectl
# (tests/fake/kubectl) so it runs without a cluster, in CI. The cluster
# smoke test proves the happy path on real garage; this proves what the
# script does when a call fails, which a live cluster will not do on
# demand:
#   - a failed `key import` must not print the secret it was given
#   - an admin API that fails between the membership poll and the layout
#     step must be fatal, not "all nodes already assigned"
#   - a key lookup that fails must be fatal, not "no such key, mint one"
# Each is something the script once got wrong, and each would pass a
# reading of the output: the wrong behaviour is a clean exit 0 with a
# plausible line, or an exit 1 whose message carries the credential.
#
# Needs bash, jq and base64. Run: garage/tests/init-faults.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
init="$here/../../bootstrap/garage-init.sh"
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
ok() { echo "ok   $*"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A credential the test can recognise in output. Both keys get the same
# Secret; the fake does not care, and the script compares per key.
want_id=GKtest000000000000000000aa
want_secret=TESTSECRET-must-never-appear-in-output-0123456789
secret_json="$(jq -cn --arg id "$want_id" --arg s "$want_secret" \
  '{data: {AWS_ACCESS_KEY_ID: ($id | @base64), AWS_SECRET_ACCESS_KEY: ($s | @base64)}}')"

# Runs the script once under the fake. Fake knobs come from the caller's
# environment; the caller reads $out (combined output), $calls (one line
# per kubectl call) and $rc.
run_init() { # <case name>
  out="$tmp/$1.out"; calls="$tmp/$1.calls"; : >"$calls"
  rm -f "$calls.matched"
  PATH="$here/fake:$PATH" FAKE_LOG="$calls" GARAGE_NS=garage-test \
    bash "$init" >"$out" 2>&1
  rc=$?
}
has() { grep -qE "$1" "$2"; }

echo "--- import path, nothing failing"
FAKE_SECRET_JSON="$secret_json" run_init import
if [ "$rc" -eq 0 ]; then ok "exits 0"; else fail "exit $rc:"; cat "$out"; fi
has '^layout: applied version 1 \(3 node\(s\) assigned\)$' "$out" && ok "lays out three nodes" || fail "no layout applied: $(cat "$out")"
[ "$(grep -c 'garage layout assign' "$calls")" = 3 ] && ok "one assign per node" || fail "assigns: $(grep -c 'layout assign' "$calls")"
has "^key: claude-worker imported from claude-pods/garage-s3-reference \($want_id\)$" "$out" && ok "imports the RO key" || fail "RO key not imported"
has "^key: claude-seed imported from claude-pods/garage-s3-seed \($want_id\)$" "$out" && ok "imports the RW key" || fail "RW key not imported"
! has 'garage key create' "$calls" && ok "mints nothing" || fail "minted a key with a Secret to import"
has '^grant: claude-seed has RW on claude-reference$' "$out" && ok "grants reach the end" || fail "grants missing"
! has "$want_secret" "$out" && ok "secret not in output" || fail "secret printed on the success path"

echo "--- mint path: no Secret, no ExternalSecret"
run_init mint
[ "$rc" -eq 0 ] && ok "exits 0" || { fail "exit $rc:"; cat "$out"; }
[ "$(grep -c 'garage key create' "$calls")" = 2 ] && ok "mints both keys" || fail "key create calls: $(grep -c 'key create' "$calls")"
has '^=== credentials' "$out" && has 'vault kv put kv/garage/' "$out" && ok "prints the seeding block" || fail "no credentials block: $(cat "$out")"

echo "--- a failed key import must not print the secret"
FAKE_SECRET_JSON="$secret_json" FAKE_FAIL='^key import' run_init import-fails
[ "$rc" -ne 0 ] && ok "exits non-zero" || fail "exited 0 after a failed import"
has "^FATAL: garage key import --yes -n claude-worker $want_id <secret> failed" "$out" && ok "names the failed import" || fail "no FATAL for the import: $(cat "$out")"
! has "$want_secret" "$out" && ok "secret not in output" || fail "the secret is in the output"

echo "--- admin API fails between the membership poll and the layout step"
# The script asks for the cluster status three times before it assigns
# anything: the membership poll, the dead-roles gate, and the member list
# the layout loop reads. The third is the one that used to turn a fault
# into "all nodes already assigned".
FAKE_SECRET_JSON="$secret_json" FAKE_FAIL='^json-api GetClusterStatus' FAKE_FAIL_FROM=3 run_init status-fails
[ "$rc" -ne 0 ] && ok "exits non-zero" || fail "exited 0 with the admin API down"
[ "$(grep -c 'json-api GetClusterStatus' "$calls")" = 3 ] && ok "fault landed on the layout step's read" || fail "GetClusterStatus calls: $(grep -c GetClusterStatus "$calls") (test placement is off)"
! has 'already assigned' "$out" && ok "does not report nodes as assigned" || fail "reported 'already assigned' on a fault"
! has 'garage layout apply' "$calls" && ok "applies no layout" || fail "applied a layout"
has '^FATAL: garage json-api GetClusterStatus failed' "$out" && ok "reports the fault" || fail "fault not reported: $(cat "$out")"

echo "--- key lookup fails with import switched off: must not mint"
existing='[{"id":"GKexisting000000000000000","name":"claude-worker","created":"2026-01-01T00:00:00Z","expiration":null,"expired":false}]'
GARAGE_KEY_RO_SECRET= GARAGE_KEY_RW_SECRET= FAKE_KEYS="$existing" FAKE_FAIL='^(json-api ListKeys|key info)' run_init lookup-fails
[ "$rc" -ne 0 ] && ok "exits non-zero" || fail "exited 0 with the key lookup failing"
! has 'garage key create' "$calls" && ok "mints nothing" || fail "minted a key next to the existing one"
! has 'garage key import' "$calls" && ok "imports nothing" || fail "imported over the existing key"

echo "--- two keys share a name: refuse to pick"
twins='[{"id":"GKtwin0000000000000000001","name":"claude-worker"},{"id":"GKtwin0000000000000000002","name":"claude-worker"}]'
GARAGE_KEY_RO_SECRET= GARAGE_KEY_RW_SECRET= FAKE_KEYS="$twins" run_init twins
[ "$rc" -ne 0 ] && ok "exits non-zero" || fail "exited 0 with two keys named claude-worker"
has '^FATAL: more than one key in garage is named claude-worker' "$out" && ok "says which name" || fail "no FATAL for the twins: $(cat "$out")"
! has 'garage key create' "$calls" && ok "mints nothing" || fail "minted a third"

echo "--- existing key whose secret differs from the Secret: ERROR, exit 1"
FAKE_KEYS="[{\"id\":\"$want_id\",\"name\":\"claude-worker\"},{\"id\":\"$want_id\",\"name\":\"claude-seed\"}]" \
  FAKE_KEY_ID="$want_id" FAKE_KEY_SECRET=something-else FAKE_SECRET_JSON="$secret_json" run_init drift
[ "$rc" -ne 0 ] && ok "exits non-zero" || fail "exited 0 with drifted secrets"
has '^ERROR: key claude-worker .* has a different secret' "$out" && ok "reports the drift" || fail "drift not reported: $(cat "$out")"
has '^grant: claude-seed has RW' "$out" && ok "still applies the grants first" || fail "grants skipped"
! has "$want_secret" "$out" && ok "secret not in output" || fail "the secret is in the output"

echo
if [ "$fails" -gt 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: garage-init.sh treats faults as faults and keeps the secret off its output"
