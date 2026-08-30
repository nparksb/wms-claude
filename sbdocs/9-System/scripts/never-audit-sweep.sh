#!/usr/bin/env bash
# Sweep every wms2-api test class containing never() through never-audit.py.
#
# Usage: never-audit-sweep.sh <repo-root>        e.g. .../v2/wms2-api or a worktree of it
#
# PAIRING. Each test class is paired to a production class so CHECK A can run. Exact-name pairing
# (XxxServiceUnitTest -> XxxService) is not enough: measured 2026-08-29, 23 of 131 test classes
# containing never() paired to NOTHING and silently degraded to CHECK-B-only, hiding 91 never()
# sites -- roughly HALF the analysable population. They are exactly the shapes where stale
# prohibitions collect, e.g. UserGroupServiceTransactionBoundaryTest (22 sites) -> UserGroupService,
# UserServiceTransactionBoundaryTest (16) -> UserService, ReplenishOrderJobPaginationTest (7).
# So: strip the trailing Test/UnitTest, then fall back to the LONGEST production class name that is
# a prefix of what remains. CHECK B never depended on the pairing and is unaffected either way.
set -u
ROOT="${1:?usage: never-audit-sweep.sh <repo-root>}"
AUD="$(cd "$(dirname "$0")" && pwd)/never-audit.py"
cd "$ROOT" || exit 1

IDX=$(mktemp); trap 'rm -f "$IDX"' EXIT
find src/main/java -name '*.java' -printf '%f\t%p\n' | sed 's/\.java\t/\t/' | sort > "$IDX"

grep -rl "never()" src/test/java | sort | while read -r T; do
  CAND=$(basename "$T" .java | sed -E 's/(UnitTest|Test)$//')
  # exact match first, then longest production name that prefixes CAND
  P=$(awk -F'\t' -v c="$CAND" '$1==c {print $2; exit}' "$IDX")
  if [ -z "$P" ]; then
    P=$(awk -F'\t' -v c="$CAND" 'index(c,$1)==1 {print length($1)"\t"$2}' "$IDX" \
        | sort -rn | head -1 | cut -f2)
  fi
  if [ -n "$P" ]; then python3 "$AUD" "$T" "$P"; else python3 "$AUD" "$T"; fi
done
