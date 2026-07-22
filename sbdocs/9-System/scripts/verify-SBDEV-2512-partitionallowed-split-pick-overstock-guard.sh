#!/usr/bin/env bash
# verify-SBDEV-2512-partitionallowed-split-pick-overstock-guard.sh
#
# Acceptance for plan:
#   sbdocs/1-Projects/wms1/plan/SBDEV-2512-partitionallowed-split-pick-overstock-guard.md
#
# Honor partitionallowed=false in overstock release: a non-partitionable
# CustomerorderPosition that cannot be filled from a SINGLE covering stock unit is
# HELD (Fix A, phase 2) instead of fragmented; a fillable one gets exactly ONE pick
# (Fix B, phase 3). Both gate on the default-ON ENFORCE_PARTITIONALLOWED kill-switch.
#
# Reinstated via PR #194 after the #192 revert (recreated script).
#
# Run:  bash sbdocs/9-System/scripts/verify-SBDEV-2512-partitionallowed-split-pick-overstock-guard.sh
# Exit 0 iff all checks pass. Override PROJECT_ROOT for a non-default checkout.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v1/wms-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0
run()  { local id=$1 desc=$2; shift 2; if "$@" >/dev/null 2>&1; then printf "  PASS  %-8s  %s\n" "$id" "$desc"; PASS=$((PASS+1)); else printf "  FAIL  %-8s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi; }
skip() { printf "  SKIP  %-8s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }
file_contains()     { grep -qE "$1" "$2" 2>/dev/null; }
count_at_least()    { [ "$(grep -cE "$1" "$2" 2>/dev/null)" -ge "$3" ]; }
mvn_test_passes()   { mvn -o test -Dtest="$1" -DfailIfNoTests=false -Dmaven.javadoc.skip=true >/dev/null 2>&1; }

CONST=src/main/java/net/aim_ai/wms/service/WmsConstants.java
ROJS=src/main/java/net/aim_ai/wms/service/job/ReleaseOrderJobService.java
TEST=src/test/java/net/aim_ai/wms/unit/service/job/ReleaseOrderJobServiceUnitTest.java

echo
echo "verify-SBDEV-2512-partitionallowed-split-pick-overstock-guard — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# --- kill-switch constant + read ---------------------------------------------
run V1 "WmsConstants defines SYSTEM_PROPERTY_ENFORCE_PARTITIONALLOWED_KEY" \
    file_contains 'SYSTEM_PROPERTY_ENFORCE_PARTITIONALLOWED_KEY\s*=\s*"ENFORCE_PARTITIONALLOWED"' "$CONST"
run V2 "releaseOrder reads the kill-switch via findSysvalueBySyskey(...ENFORCE_PARTITIONALLOWED...)" \
    file_contains 'findSysvalueBySyskey\(\s*WmsConstants\.SYSTEM_PROPERTY_ENFORCE_PARTITIONALLOWED_KEY' "$ROJS"

# --- Fix A: cumulative phase-2 hold ------------------------------------------
run V3a "reserveSingleCoveringUnit helper present" \
    file_contains 'private boolean reserveSingleCoveringUnit\(' "$ROJS"
run V3b "reserveSingleCoveringUnit queries getStockUnitsByItemDataId (per-unit net ledger)" \
    file_contains 'getStockUnitsByItemDataId' "$ROJS"
run V3c "Fix A holds via RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION (state 55)" \
    file_contains 'RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION' "$ROJS"

# --- getPartitionallowed read in BOTH phases (Fix A @~245 + Fix B @487-538) ---
run V4 "getPartitionallowed() read >=2x (phase-2 guard + phase-3 branch)" \
    count_at_least 'getPartitionallowed\(\)' "$ROJS" 2

# --- Fix B: phase-3 single-covering-unit failsafe ----------------------------
run V5 "Fix B failsafe throws BusinessException 'SBDEV-2512: no single stock unit covers'" \
    file_contains 'SBDEV-2512: no single stock unit covers non-partitionable position' "$ROJS"

# --- Behavioral gate — unit tests (incl. AC-5 divergence, AC-6 cumulative hold)
if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T "ReleaseOrderJobServiceUnitTest passes (incl. AC-1..AC-6)" \
        mvn_test_passes ReleaseOrderJobServiceUnitTest
else
    skip T "Targeted unit-test run" "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
