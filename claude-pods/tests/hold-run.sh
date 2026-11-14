#!/usr/bin/env bash
# hold-run.sh pins a scale-to-zero pod open for the length of one run.
# Its whole value is the release: a hold left behind pins the pod at 1
# replica indefinitely and the next scheduled run never gets a fresh
# one. So these tests are mostly about cleanup paths.
#
# They drive the script against a fake kubectl on PATH, which is the
# only way to exercise a release-time failure without breaking a real
# cluster. Three of the four cases here correspond to defects found in
# review that the script shipped with:
#
#   - release re-queried the cluster to decide whether the target was
#     KEDA-backed, so a transient `kubectl get` failure at cleanup made
#     it take the wrong branch and never unpin;
#   - the busy check matched comm == "claude" when the shipped binary is
#     claude.exe, so it never fired;
#   - `set -e` aborted before the rc report on exactly the failures
#     worth reporting.
#
# Run: claude-pods/tests/hold-run.sh
set -uo pipefail
fail=0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../hold-run.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
log="$tmp/calls.log"

# $FK_GET_SO: ok | fail-after-first | missing
make_kubectl() {
  cat > "$tmp/bin/kubectl" <<EOF
#!/bin/sh
echo "kubectl \$*" >> "$log"
case "\$1" in
  get)
    case "\$2" in
      scaledobject)
        case "\${FK_GET_SO:-ok}" in
          missing) exit 1 ;;
          fail-after-first)
            n=\$(grep -c "get scaledobject" "$log")
            [ "\$n" -gt 1 ] && exit 1
            exit 0 ;;
          *) exit 0 ;;
        esac ;;
      pod) echo true; exit 0 ;;
    esac ;;
  annotate|scale) exit 0 ;;
  exec)
    case "\$*" in *flock*) echo "\${FK_BUSY:-idle}"; exit 0 ;; esac
    exit "\${FK_RC:-0}" ;;
esac
exit 0
EOF
  chmod +x "$tmp/bin/kubectl"
}
make_kubectl

run() { : > "$log"; PATH="$tmp/bin:$PATH" bash "$script" "$@" 2>&1; }
count() { grep -c "$1" "$log" 2>/dev/null | head -1; }
unpins() { count 'annotate.*paused-replicas-'; }

check() {
  local what=$1 want=$2 got=$3
  if [ "$want" != "$got" ]; then
    echo "FAIL: $what"
    echo "      want [$want] got [$got]"
    fail=1
  fi
}

# 1. The happy path unpins.
out=$(run desloppify)
check "unpins after a clean run" 1 "$(unpins)"

# 2. A failing run still unpins, and reports the code. Under `set -e` the
#    report line was unreachable, which is the case you most want it.
out=$(FK_RC=7 run desloppify)
check "unpins after a failed run" 1 "$(unpins)"
printf '%s' "$out" | grep -q 'finished rc=7' \
  || { echo "FAIL: a failing run does not report its exit code"; fail=1; }

# 3. The regression that matters: `kubectl get` fails at release time.
#    The decision must have been captured at startup, not re-queried.
out=$(FK_GET_SO=fail-after-first run desloppify)
check "unpins when the cluster is unreachable at release" 1 "$(unpins)"
printf '%s' "$out" | grep -q 'session-sleep owns it' \
  && { echo "FAIL: release took the non-KEDA branch after a transient failure"; fail=1; }

# 4. A busy pod is refused, and nothing is pinned on the way out. The
#    probe answers with the real comm, claude.exe - an exact match on
#    "claude" never fires.
out=$(FK_BUSY=busy run desloppify)
printf '%s' "$out" | grep -q 'already running something' \
  || { echo "FAIL: a busy pod was not refused"; fail=1; }
check "does not pin when refusing a busy pod" 0 \
  "$(count 'annotate.*paused-replicas=')"

# 4b. `--release` takes an early path that skips startup, so it has to
#     resolve the KEDA decision itself. It did not, and shipped briefly
#     taking the wrong branch - found by running it against a real hold,
#     which it failed to drop while reporting success.
out=$(run --release desloppify)
check "--release unpins" 1 "$(unpins)"
printf '%s' "$out" | grep -q 'session-sleep owns it' \
  && { echo "FAIL: --release took the non-KEDA branch"; fail=1; }

# 4c. And it must still unpin when the lookup fails, for the same reason
#     the trap path must: this subcommand exists to undo a stuck hold.
out=$(FK_GET_SO=missing run --release desloppify)
check "--release unpins even when the lookup fails" 1 "$(unpins)"

# 5. Run the probe's OWN logic against a fake /proc holding a process
#    called claude.exe - the real binary's name. A test that greps the
#    probe's source passes on any spelling; this one only passes if the
#    matcher actually fires.
# Anchored on the probe's own first line, not on the phrase as it also
# appears in the top-of-file comment - that range started at line 15 and
# swallowed most of the script, and only worked because the next sed
# narrowed it back down.
probe=$(sed -n '/flock -n \/tmp\/nightly.lock true/,/echo idle/p' "$script" \
        | sed -e 's/^ *//' -e '/^#/d')
fakeproc="$tmp/proc"; mkdir -p "$fakeproc/4242"
printf 'claude.exe\n' > "$fakeproc/4242/comm"
verdict=$(cd "$fakeproc" && sh -c "
  for p in ./[0-9]*; do
    [ -r \"\$p/comm\" ] || continue
    read -r c < \"\$p/comm\" 2>/dev/null
    $(printf '%s' "$probe" | sed -n '/case "\$c"/p;/\[ "\$c" = claude \]/p')
  done
  echo idle" 2>/dev/null)
check "the busy probe matches claude.exe" "busy" "$verdict"

# 6. env assignments and positional arguments must not be spliced
#    together: `env` runs the first word that is not NAME=VALUE, so
#    `env task repo /usr/local/bin/stage-author` dies with
#    "env: task: No such file or directory".
out=$(run author CLA-13 app 2>&1)
grep -q 'env .*CLA-13 app /usr/local/bin/stage-author' "$log" \
  && { echo "FAIL: positional args are spliced into env"; fail=1; }
grep -q 'stage-author CLA-13 app' "$log" \
  || { echo "FAIL: positional args do not reach the stage script"; fail=1; }

# 7. The stage scripts install as stage-*, not nightly-*.
for kind in author test merge; do
  grep -q "/usr/local/bin/stage-$kind" "$script" \
    || { echo "FAIL: $kind does not resolve to /usr/local/bin/stage-$kind"; fail=1; }
done

if [ "$fail" -eq 0 ]; then
  echo "PASS: hold-run releases its hold on every exit path, refuses a busy pod, and passes arguments through correctly"
fi
exit "$fail"
