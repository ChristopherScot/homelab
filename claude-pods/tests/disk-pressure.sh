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

# Reap stand-in agents as well as the tmpdir. Case 4 deliberately TERMs
# the stage shell while its `claude` is alive, so that process outlives
# the case - and a later case asking "is an agent running" would see it
# and judge the guard on a corpse of an earlier test. Matching on the
# copy's own path, never on the name, so a real claude (an attached
# Remote Control session, a developer's own) is never signalled.
reap_standins() {
  [ -x "$tmp/bin/claude" ] || return 0
  [ -d /proc ] || return 0
  local d
  for d in /proc/[0-9]*; do
    [ -r "$d/exe" ] || continue
    case "$(readlink "$d/exe" 2>/dev/null)" in
      "$tmp/bin/claude"*) kill "$(basename "$d")" 2>/dev/null ;;
    esac
  done
  # Give them a moment to leave the process table, or the next case
  # sees a dying stand-in and judges the guard on it.
  sleep 0.3
}
cleanup() { reap_standins; rm -rf "$tmp"; }
trap cleanup EXIT

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

# A harness shell built the way a stage builds itself.
#
# It calls log_to before installing the trap, because that is the stage
# preamble's order (stage-author.sh, stage-test.sh, stage-merge.sh all
# do log_to -> ... -> trap). That ordering is not incidental: log_to
# does `exec > >(tee ...)`, which forks a tee that is a direct child of
# the stage shell and lives for the whole run. A guard that asks "do I
# have a child" therefore never lets the prune run - a bug that every
# test here passed straight through while the harness was a sketch of a
# stage rather than the shape of one. Build the subject the way
# production builds it.
harness() {
  cat > "$tmp/run.sh" <<H
#!/bin/bash
export PATH="$tmp/bin:\$PATH"
export PRUNE_LOG="$tmp/pruned.log"
set +u; . "$lib" 2>/dev/null; set -u
HOME_TIGHT_PCT=$2
df() { printf 'x\n/d 100 1 99 $1%% /\n'; }
log_to "$tmp/stage.log"
trap prune_build_caches EXIT
echo \$\$ > "$tmp/victim.pid"
$3
H
  bash "$tmp/run.sh" >"$tmp/out" 2>&1
  # log_to redirects the shell's own output into the tee, so the
  # diagnostics land in the stage log rather than on stdout.
  cat "$tmp/stage.log" >> "$tmp/out" 2>/dev/null || true
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

# 4. The guard must survive TERM arriving from OUTSIDE while the agent
#    is still alive. A background timer inside the harness would make a
#    `jobs`-based guard pass for the wrong reason, so the signal is sent
#    from here. The stand-in is named `claude` because that is what the
#    guard looks for - it asks whether THE AGENT is running, not whether
#    any child is.
#
#    Linux only, and not because of a quirk of the test: a developer's
#    Mac usually has several real `claude` processes of its own (editor
#    sessions, other agents), none of them descendants of this shell.
#    The guard correctly ignores them, so there is nothing here to
#    observe. On Linux - CI and the pod - it runs and it gates: the
#    any-child and name-only regressions both fail the suite on a clean
#    ubuntu/node image with no claude running at all. To exercise it
#    against a real pod, with an attached Remote Control session in the
#    process table:
#      kubectl exec -n claude-pods claude-session-0 -- bash <path>/disk-pressure.sh
cp "$(command -v sleep)" "$tmp/bin/claude"
if [ -d /proc ]; then
: > "$tmp/pruned.log"; rm -f "$tmp/victim.pid"
( harness 99 1 'out=$(bash -c '"'"'trap "" TERM; claude 6'"'"')' ) 2>/dev/null &
hpid=$!
for _ in $(seq 1 60); do [ -s "$tmp/victim.pid" ] && break; sleep 0.1; done
[ -s "$tmp/victim.pid" ] || fail "harness never reported its pid"
sleep 0.4
kill -TERM "$(cat "$tmp/victim.pid")" 2>/dev/null
wait $hpid 2>/dev/null
if pruned; then
  echo "--- DIAG: case 4 state at failure ---" >&2
  echo "stage pid was: $(cat "$tmp/victim.pid" 2>/dev/null)" >&2
  echo "claude procs now:" >&2
  for d in /proc/[0-9]*; do
    [ -r "$d/comm" ] || continue
    read -r c < "$d/comm" 2>/dev/null
    [ "$c" = claude ] || continue
    st=$(sed -e 's/.*) //' "$d/stat" 2>/dev/null)
    echo "  pid=$(basename "$d") state=$(printf '%s' "$st" | awk '{print $1}') ppid=$(printf '%s' "$st" | awk '{print $2}') exe=$(readlink "$d/exe" 2>/dev/null)" >&2
  done
  echo "--- harness out ---" >&2; tail -5 "$tmp/out" >&2
  echo "--- stage log ---" >&2; tail -5 "$tmp/stage.log" 2>/dev/null >&2
  fail "pruned while the agent was still running: go clean -modcache can delete the module cache mid-run"
fi
grep -q 'NOT pruned' "$tmp/out" \
  || fail "no diagnostic when the prune was skipped for a live agent"
# This case TERMs the stage shell while its agent is alive, so the
# stand-in outlives it. Reap it here: 4b asserts that the prune DOES
# run, and a survivor from this case would make it fail for a reason
# that has nothing to do with what 4b is testing.
reap_standins
fi

# 4b. log_to's tee must NOT look like a running agent.
#
#     This is the case that matters most, because it is the one that
#     shipped broken. Every stage calls log_to before installing the
#     trap, and log_to does `exec > >(tee ...)`, which forks a tee that
#     is a direct child of the stage shell for the whole run. A guard
#     that asks "do I have a child" therefore skips the prune on every
#     exit of every stage, forever - the ENOSPC fix dead on arrival,
#     announcing in the log that it deliberately did nothing.
#
#     The harness already calls log_to, so this case just asserts the
#     prune happens with the tee alive and no agent running.
#
#     This one runs everywhere, CI included, and it gates there:
#     reverting the guard to "any child" fails it on a clean Linux
#     image with no claude process of any kind running.
: > "$tmp/pruned.log"
harness 99 85 'true'
pruned || fail "did not prune with log_to's tee alive: the guard mistakes the stage's own logging for a running agent"

# 4c. An unrelated `claude` that is NOT a descendant of this shell must
#     not block the prune either. An attached Remote Control session
#     (claude --remote-control, under tmux) is exactly that, and it can
#     be attached for hours - blocking the prune whenever a human is
#     looking at the pod is the opposite of useful.
if [ -d /proc ]; then
  : > "$tmp/pruned.log"
  setsid "$tmp/bin/claude" 8 >/dev/null 2>&1 &
  outsider=$!
  sleep 0.4
  harness 99 85 'true'
  kill $outsider 2>/dev/null
  pruned || fail "an unrelated claude process (e.g. an attached Remote Control session) blocked the prune"
fi

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
