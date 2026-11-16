#!/usr/bin/env bash
# The interactive image (Dockerfile) and the task image (task/Dockerfile)
# both ship the Go worker and the same toolchain until the dispatcher is
# retargeted, and each pins its versions in its own ARG lines. A pin bumped
# in one file and not the other ships two different workers, or two Go
# toolchains, under a README that says they match. Nothing at build time
# compares them; this does, for every ARG name the two files share.
#
# Run: claude-pods/tests/image-pins.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0

pins() { grep -oE '^ARG [A-Z0-9_]+=[^ ]+' "$1" | sed 's/^ARG //' | sort; }
shared=$(comm -12 <(pins "$here/Dockerfile" | cut -d= -f1) <(pins "$here/task/Dockerfile" | cut -d= -f1))
[ -n "$shared" ] || { echo "FAIL: the two Dockerfiles share no ARG pins; expected at least KANEO_WORKER_REF"; exit 1; }

for name in $shared; do
  a=$(pins "$here/Dockerfile" | grep "^$name=" | cut -d= -f2-)
  b=$(pins "$here/task/Dockerfile" | grep "^$name=" | cut -d= -f2-)
  if [ "$a" != "$b" ]; then
    echo "FAIL: $name is $a in claude-pods/Dockerfile but $b in claude-pods/task/Dockerfile"
    fail=1
  fi
done

[ "$fail" -eq 0 ] && echo "PASS: every ARG pin shared by the two Dockerfiles matches ($(echo "$shared" | tr '\n' ' '))"
exit "$fail"
