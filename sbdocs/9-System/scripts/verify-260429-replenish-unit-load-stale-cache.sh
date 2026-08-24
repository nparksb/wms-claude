#!/usr/bin/env bash
# verify-260429-replenish-unit-load-stale-cache.sh
#
# Acceptance for plan: 260429-replenish-unit-load-stale-cache.md
# Two fixes — Fix A (remove cache-read branch in selectUnitLoad.vue) and
# Fix B (update stale comment in selectSource.vue).
#
# Run after every implementation pass:
#   $ bash sbdocs/9-System/scripts/verify-260429-replenish-unit-load-stale-cache.sh
#
# Exit code 0 = all checks pass. Non-zero = at least one FAIL.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v1/wms-mobile-ui}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-12s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-12s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

file_contains()     { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2" 2>/dev/null; }

UL=components/replenish/process/selectUnitLoad.vue
SRC=components/replenish/process/selectSource.vue

echo
echo "verify-260429-replenish-unit-load-stale-cache"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# ---------------------------------------------------------------------------
# Fix A — cache-read branch removed from selectUnitLoad.vue.fetchSourceOptions
# ---------------------------------------------------------------------------

# POSITIVE: the unconditional fetchUnitLoadsForItem call must still be present
run FA-1 "Fix A — fetchUnitLoadsForItem called unconditionally" \
    file_contains 'allSourceOptions\s*=\s*await\s+fetchUnitLoadsForItem' "$UL"

# POSITIVE: the commit that writes to cache must still be present (overwrites stale entry)
run FA-2 "Fix A — setUnitLoadsForItem commit present after fetch" \
    file_contains "replenish/setUnitLoadsForItem" "$UL"

# NEGATIVE: the 'const cached = ...' variable declaration must be gone
run FA-3 "Fix A — 'const cached' cache-read variable removed" \
    file_not_contains 'const\s+cached\s*=' "$UL"

# NEGATIVE: the 'if (cached && Array.isArray(cached) && cached.length)' branch must be gone
run FA-4 "Fix A — cache-hit branch (if cached) removed" \
    file_not_contains 'if\s*\(\s*cached\s*&&\s*Array\.isArray\(cached\)' "$UL"

# NEGATIVE: the direct unitLoadsCache read in fetchSourceOptions must be gone
run FA-5 "Fix A — direct unitLoadsCache read in fetchSourceOptions removed" \
    file_not_contains 'unitLoadsCache\[itemDataId\]' "$UL"

echo

# ---------------------------------------------------------------------------
# Fix B — stale comment updated in selectSource.vue
# ---------------------------------------------------------------------------

# NEGATIVE: the original misleading sentence must be gone
run FB-1 "Fix B — stale 'will reuse the cached result' comment removed" \
    file_not_contains 'selectUnitLoad will reuse the cached result without another call' "$SRC"

# POSITIVE: the clearUnitLoadsForItem commit must still be present (behavior unchanged)
run FB-2 "Fix B — clearUnitLoadsForItem commit still present" \
    file_contains "replenish/clearUnitLoadsForItem" "$SRC"

echo

echo "Result: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
