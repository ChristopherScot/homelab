#!/usr/bin/env bash
# Regression test for the 2026-11-12 ENOSPC incident and for the two
# ways the fix for it can go wrong.
#
# The incident: pod2's home hit 100%, Claude Code could not write its
# session transcript, the agent exited non-zero AFTER reaching a PASS
# verdict, and stage-test read that exit code as "the pod could not run
# this" and parked the card as BLOCKED. A full disk looked like a broken
# ticket.
#
# prune_build_caches fixes that, and has two failure modes of its own
# that this pins:
#
#   1. it must NOT prune while a child is still running. The EXIT trap
#      fires as soon as bash stops waiting, which on SIGTERM is before a
#      TERM-ignoring agent has died; pruning there deletes the module
#      cache mid `go test` and the agent reports missing packages -
#      the same environmental-fault-as-ticket failure, by another route.
#      The agent runs in the FOREGROUND inside $(...), so a `jobs`-based
#      guard is empty in exactly this case: the guard must see a
#      foreground child.
#   2. it must prune only under real pressure. Each stage is pinned to
#      its own pod and home PVC, so tomorrow's run reuses today's
#      caches; dropping them every time trades a BLOCKED-on-full-disk
#      for a BLOCKED-on-timeout.
#
# And the exit code must survive the trap either way, or a passing run
# still reports failure - the incident's actual mechanism.
#
# Run: claude-pods/tests/disk-pressure.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
pods="$here/.."
lib="$pods/lib/pod-common.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*"
  exit 1
}

mkdir -p "$tmp/bin"
# Stub go so a prune is observable without touching the real caches.
cat > "$tmp/bin/go" <<'G'
#!/bin/sh
echo "pruned $*" >> "$PRUNE_LOG"
G
chmod +x "$tmp/bin/go"

# A harness shell: sources the library, fakes df at a given fullness,
# installs the real trap, and optionally holds a TERM-ignoring
# foreground child so the trap fires while it is alive.
harness() {
  cat > "$tmp/run.sh" <<H
#!/bin/bash
export PATH="$tmp/bin:\$PATH"
export PRUNE_LOG="$tmp/pruned.log"
set +u; . "$lib" 2>/dev/null; set -u
HOME_TIGHT_PCT=$2
df() { printf 'x\n/d 100 1 99 $1%% /\n'; }
trap prune_build_caches EXIT
echo \$\$ > "$tmp/victim.pid"
$3
H
  bash "$tmp/run.sh" >"$tmp/out" 2>&1
}

: > "$tmp/pruned.log"
pruned() { grep -q pruned "$tmp/pruned.log"; }

# 1. Under pressure and with nothing running, it prunes.
: > "$tmp/pruned.log"
harness 99 85 'true'
pruned || fail "did not prune at 99% full with no child running"

# 2. Below the threshold it leaves the caches alone - they are what
#    keeps the next run inside PER_TICKET_TIMEOUT.
: > "$tmp/pruned.log"
harness 50 85 'true'
pruned && fail "pruned at 50% full; caches must survive when there is no pressure"

# 3. The threshold is shared with the warning and is overridable, so
#    tuning it is one env var rather than two edits.
grep -q 'HOME_TIGHT_PCT:-' "$lib" \
  || fail "HOME_TIGHT_PCT has no default/override in $lib"
for fn in prune_build_caches warn_if_home_tight; do
  awk "/^${fn}\(\)/,/^}/" "$lib" | grep -q 'HOME_TIGHT_PCT' \
    || fail "$fn does not use the shared HOME_TIGHT_PCT threshold"
done

# 4. The guard must survive TERM arriving from OUTSIDE with a
#    TERM-ignoring child in the foreground. A background timer inside
#    the harness would make a `jobs` guard pass for the wrong reason,
#    so the signal is sent from here.
: > "$tmp/pruned.log"; rm -f "$tmp/victim.pid"
( harness 99 1 'out=$(bash -c '"'"'trap "" TERM; sleep 6'"'"')' ) 2>/dev/null &
hpid=$!
for _ in $(seq 1 60); do [ -s "$tmp/victim.pid" ] && break; sleep 0.1; done
[ -s "$tmp/victim.pid" ] || fail "harness never reported its pid"
sleep 0.4
kill -TERM "$(cat "$tmp/victim.pid")" 2>/dev/null
wait $hpid 2>/dev/null
pruned && fail "pruned while a foreground child was still running: go clean -modcache can delete the module cache mid-run"
grep -q 'NOT pruned' "$tmp/out" \
  || fail "no diagnostic when the prune was skipped for a live child"

# 5. The trap must not eat the stage's exit code. This is the incident's
#    own mechanism: a good run that reports non-zero is read as BLOCKED.
#
#    Bash fixes the script's status BEFORE running the EXIT trap, so a
#    failing command inside prune_build_caches cannot corrupt it - that
#    was checked rather than assumed, and it is why there is no test for
#    it here. What this pins instead is the reachable way to lose the
#    code: a future `exit` or `set -e` interaction added to the trap
#    body. Both endings and both pressures, so a prune that runs and one
#    that is skipped are each covered.
for pct in 99 50; do
  for ending in 'exit 0' 'exit 7' ''; do
    case "$ending" in 'exit 7') want=7;; *) want=0;; esac
    bash -c "export PATH='$tmp/bin:\$PATH' PRUNE_LOG='$tmp/pruned.log'
      set +u; . '$lib' 2>/dev/null; set -u
      HOME_TIGHT_PCT=85
      df() { printf 'x\n/d 100 1 99 $pct%% /\n'; }
      trap prune_build_caches EXIT
      true
      $ending" >/dev/null 2>&1
    got=$?
    [ "$got" = "$want" ] \
      || fail "trap changed exit code at ${pct}% full (ending: ${ending:-fall off end}): wanted $want, got $got"
  done
done

echo "PASS: prune_build_caches prunes only under pressure, refuses while a foreground child is alive, shares HOME_TIGHT_PCT with the warning, and preserves the stage's exit code"
