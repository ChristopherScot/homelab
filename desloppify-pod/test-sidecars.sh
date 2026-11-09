#!/usr/bin/env bash
# The test sidecars must match the compose file they mirror.
#
# projects/webapp/src/tests/docker-compose.yml lives in another repo and
# changes without reference to this one. The sidecars exist so the vitest
# suite can reach Hasura, Postgres and Redis on localhost at the ports
# .env.test.local already names; if the compose file gains a service or
# moves a port, the suite breaks in a way that reads as a test failure
# rather than a configuration one.
#
# `docker compose config` does the parsing - it normalises the file the
# same way the tool that runs it does, which a YAML reader here would
# only approximate. Without docker, or without the app repo, the check
# reports what it could not do and passes: a missing checkout is not
# evidence of drift.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
spec="$here/desloppify-statefulset.yaml"
compose="${APP_REPO:-$HOME/app}/projects/webapp/src/tests/docker-compose.yml"
fail=0

if [ ! -f "$compose" ]; then
  echo "SKIP - no compose file at $compose (set APP_REPO to the app checkout)"
  exit 0
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP - docker is not available to parse the compose file"
  exit 0
fi

services=$(docker compose -f "$compose" config --services 2>/dev/null | sort)
if [ -z "$services" ]; then
  echo "SKIP - could not parse $compose"
  exit 0
fi

# Every service in the compose file needs a sidecar of the same name.
while read -r svc; do
  [ -n "$svc" ] || continue
  if ! grep -qE "^\s+- name: ${svc}\s*$" "$spec"; then
    echo "FAIL: compose defines '$svc' but the pod has no such sidecar"
    fail=1
  fi
done <<< "$services"

# And the images must agree, or the sidecar is a different thing wearing
# the same name.
while read -r svc; do
  [ -n "$svc" ] || continue
  want=$(docker compose -f "$compose" config --format json 2>/dev/null \
         | python3 -c "import json,sys; print(json.load(sys.stdin)['services']['$svc']['image'])" 2>/dev/null)
  [ -n "$want" ] || continue
  if ! grep -qF "image: $want" "$spec"; then
    echo "FAIL: compose runs '$svc' on $want; the pod does not"
    fail=1
  fi
done <<< "$services"

# The host-side ports are what the suite dials. A sidecar has no host
# side, so it must be told to listen on that port directly.
ports=$(docker compose -f "$compose" config --format json 2>/dev/null \
        | python3 -c "
import json,sys
d=json.load(sys.stdin)
for s in d.get('services',{}).values():
    for p in s.get('ports',[]):
        pub = p.get('published') if isinstance(p,dict) else str(p).split(':')[0]
        if pub: print(pub)
" 2>/dev/null | sort -u)

while read -r port; do
  [ -n "$port" ] || continue
  if ! grep -qE "\"?${port}\"?" "$spec"; then
    echo "FAIL: the suite dials port $port; no sidecar listens on it"
    fail=1
  fi
done <<< "$ports"

# They must be native sidecars. An initContainer without
# restartPolicy: Always runs once and exits, so the pod would wait
# forever for a database that has already stopped.
while read -r svc; do
  [ -n "$svc" ] || continue
  if ! awk -v s="$svc" '
    $0 ~ "- name: " s "$" { found=1; next }
    found && /restartPolicy: Always/ { ok=1; exit }
    found && /- name: / { exit }
    END { exit !ok }
  ' "$spec"; then
    echo "FAIL: '$svc' is not a native sidecar (no restartPolicy: Always)"
    fail=1
  fi
done <<< "$services"

# And readiness, or "started" only means the process exists - the suite
# can then run against a Postgres that is still initialising.
while read -r svc; do
  [ -n "$svc" ] || continue
  if ! awk -v s="$svc" '
    $0 ~ "- name: " s "$" { found=1; next }
    found && /readinessProbe:/ { ok=1; exit }
    found && /^        - name: / { exit }
    END { exit !ok }
  ' "$spec"; then
    echo "FAIL: '$svc' has no readinessProbe"
    fail=1
  fi
done <<< "$services"

[ "$fail" -eq 0 ] && echo "PASS - sidecars match the compose file, are native, and gate on readiness"
exit "$fail"
