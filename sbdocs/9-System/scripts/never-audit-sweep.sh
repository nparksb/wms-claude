#!/usr/bin/env bash
# Sweep every wms2-api test class containing never() through never-audit.py.
#
# Usage: never-audit-sweep.sh <repo-root>        e.g. .../v2/wms2-api or a worktree of it
#
# Pairs each test class to a production class by NAME (XxxServiceUnitTest -> XxxService). That
# heuristic is crude, which is why never-audit.py only trusts CHECK A when the paired class actually
# owns the mocked collaborator, and prints a [?] note otherwise. CHECK B does not depend on the
# pairing at all, so its counts are reliable regardless.
set -u
ROOT="${1:?usage: never-audit-sweep.sh <repo-root>}"
AUD="$(cd "$(dirname "$0")" && pwd)/never-audit.py"
cd "$ROOT" || exit 1
grep -rl "never()" src/test/java | sort | while read -r T; do
  CAND=$(basename "$T" .java | sed -E 's/(UnitTest|Test)$//')
  P=$(find src/main/java -name "${CAND}.java" | head -1)
  if [ -n "$P" ]; then python3 "$AUD" "$T" "$P"; else python3 "$AUD" "$T"; fi
done
