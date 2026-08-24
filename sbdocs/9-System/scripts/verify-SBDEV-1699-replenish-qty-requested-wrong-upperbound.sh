#!/usr/bin/env bash
# verify-SBDEV-1699-replenish-qty-requested-wrong-upperbound.sh
#
# Acceptance for SBDEV-1699-replenish-qty-requested-wrong-upperbound.md
#
# Four fix items:
#   Fix A  — ViewDtoService.getStockPerLocation: findByItemdataId + zero-guard
#   Fix B1 — ReplenishmentMonitorViewRepository: f.upperbound in t5 subquery SELECT + main SELECT + GROUP BY
#   Fix B2 — ViewDtoService.getReplenishMonitorViewSummary: locationStock field computed from result[25]
#   Fix B3 — replenish.vue fetchAllReplen: use item.locationStock (not item.qtyRequested) for held-up items
#
# Run from any directory:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-1699-replenish-qty-requested-wrong-upperbound.sh
#
# Override roots if needed:
#   PROJECT_ROOT=/path/to/wms-api MOBILE_ROOT=/path/to/wms-mobile-ui bash verify-...sh

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v1/wms-api}"
MOBILE_ROOT="${MOBILE_ROOT:-/home/nampark/dev/wms-claude/v1/wms-mobile-ui}"

cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1))
}

file_contains()     { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2" 2>/dev/null; }

SVC=src/main/java/net/aim_ai/wms/service
REPO=src/main/java/net/aim_ai/wms/repo/jpa

VIEW_SVC=$SVC/ViewDtoService.java
MONITOR_REPO=$REPO/ReplenishmentMonitorViewRepository.java
REPLENISH_VUE=$MOBILE_ROOT/pages/replenish.vue

echo
echo "verify-SBDEV-1699 — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  MOBILE_ROOT=$MOBILE_ROOT"
echo

# --- Fix A: getStockPerLocation uses findByItemdataId + zero-guard -----------

run A1 "Fix A — findByItemdataId called in getStockPerLocation" \
    file_contains 'findByItemdataId\(itemdataId\)' "$VIEW_SVC"

run A2 "Fix A — itemdataId extracted from result[13]" \
    file_contains 'result\[13\].*longValue\(\)|itemdataId.*result\[13\]' "$VIEW_SVC"

run A3 "Fix A — zero-guard on upperbound (compareTo(BigDecimal.ZERO) > 0)" \
    file_contains 'getUpperbound\(\).*compareTo.*BigDecimal\.ZERO.*>\s*0|compareTo.*BigDecimal\.ZERO.*>\s*0.*getUpperbound' "$VIEW_SVC"

run A4 "Fix A — old findByAssignedlocationId call gone from getStockPerLocation context" \
    file_not_contains 'fixLocationAssignmentRepository\.findByAssignedlocationId' "$VIEW_SVC"

echo

# --- Fix B1: f.upperbound added to t5 subquery and main SELECT ---------------

run B1a "Fix B1 — fix_assignment_upperbound in t5 subquery SELECT" \
    file_contains 'f\.upperbound\s+AS\s+fix_assignment_upperbound' "$MONITOR_REPO"

run B1b "Fix B1 — fix_assignment_upperbound in main SELECT (t5.fix_assignment_upperbound)" \
    file_contains 't5\.fix_assignment_upperbound' "$MONITOR_REPO"

run B1c "Fix B1 — fix_assignment_upperbound in GROUP BY clause" \
    file_contains 'GROUP BY.*fix_assignment_upperbound|fix_assignment_upperbound.*GROUP BY' "$MONITOR_REPO"

echo

# --- Fix B2: locationStock added to getReplenishMonitorViewSummary DTO --------

run B2a "Fix B2 — result[25] read in getReplenishMonitorViewSummary" \
    file_contains 'result\s*\[\s*25\s*\]' "$VIEW_SVC"

run B2b "Fix B2 — locationStock put into DTO in getReplenishMonitorViewSummary" \
    file_contains '"locationStock"' "$VIEW_SVC"

run B2c "Fix B2 — null-guard on result[25] before cast" \
    file_contains 'result\s*\[\s*25\s*\]\s*!=\s*null' "$VIEW_SVC"

echo

# --- Fix B3: replenish.vue uses item.locationStock for held-up items ----------

run B3a "Fix B3 — item.locationStock used in held-up mapping (not raw qtyRequested)" \
    file_contains 'item\.locationStock' "$REPLENISH_VUE"

run B3b "Fix B3 — explicit locationStock: item.qtyRequested override removed" \
    file_not_contains 'locationStock:\s*item\.qtyRequested' "$REPLENISH_VUE"

echo

# --- Optional: unit tests -----------------------------------------------------

mvn_test_passes() {
    mvn test -Dtest="$1" -DfailIfNoTests=false >/dev/null 2>&1
}

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T1 "Unit test — ViewDtoServiceTest passes" mvn_test_passes ViewDtoServiceTest
else
    skip T1 "ViewDtoServiceTest" "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
