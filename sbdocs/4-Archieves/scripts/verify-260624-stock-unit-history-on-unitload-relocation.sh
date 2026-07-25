#!/usr/bin/env bash
# verify-260624-stock-unit-history-on-unitload-relocation.sh
#
# Machine-checkable acceptance for the plan:
#   sbdocs/1-Projects/wms1/plan/260624-stock-unit-history-on-unitload-relocation.md
# Log operator whole-unit-load relocations (Move Fixed Location + Move Stock whole-UL)
# in stock-unit history via a new STOCK_RELOCATED Stockrecord.
#
# Run before the first change (FAIL baseline) and after every implementation pass.
# Final acceptance: "Result: N pass, 0 fail".
#
#   $ bash sbdocs/9-System/scripts/verify-260624-stock-unit-history-on-unitload-relocation.sh
#
# Exit code is 0 only when every check passes.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v1/wms-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-8s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-8s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}
skip() { printf "  SKIP  %-8s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

file_exists()       { test -f "$1"; }
file_contains()     { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { ! grep -qE "$1" "$2" 2>/dev/null; }
# Multi-line variant (perl -0777). Require the file to exist so a POSITIVE check
# can't pass vacuously before the file is created.
file_contains_ml()  { test -f "$2" && PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/ms; exit 1' "$2" 2>/dev/null; }
# Negative check that ignores Java comment lines (so a doc-comment naming a forbidden
# symbol does not trip a scope-guard).
code_not_contains() { ! grep -vE '^[[:space:]]*(\*|//|/\*|\*/)' "$2" 2>/dev/null | grep -qE "$1"; }

SVC=src/main/java/net/aim_ai/wms/service
WMSCONST=$SVC/WmsConstants.java
STOCKREC=$SVC/StockrecordService.java
FLA=$SVC/FixLocationAssignmentService.java
SUSVC=$SVC/StockunitService.java
ULB=$SVC/UnitloadBusinessService.java

echo
echo "verify-260624 — stock-unit history on unit-load relocation"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# --- F-A — STOCK_RELOCATED constant ------------------------------------------
run FA "F-A — StockRecordType.STOCK_RELOCATED constant present" \
    file_contains 'STOCK_RELOCATED[[:space:]]*=[[:space:]]*"STOCK_RELOCATED"' "$WMSCONST"

echo

# --- F-B — StockrecordService.recordRelocation -------------------------------
run FBa "F-B — recordRelocation(...) method declared" \
    file_contains 'void[[:space:]]+recordRelocation[[:space:]]*\(' "$STOCKREC"
run FBb "F-B — recordRelocation sets type=STOCK_RELOCATED" \
    file_contains_ml 'recordRelocation\([^{]*\{.*StockRecordType\.STOCK_RELOCATED' "$STOCKREC"
run FBc "F-B — recordRelocation sets amount = stockunit amount (moved qty shows in UI, SBDEV-2488)" \
    file_contains_ml 'recordRelocation\([^{]*\{.*setAmount\(stockunit\.getAmount\(\)\)' "$STOCKREC"

echo

# --- F-C — FixLocationAssignmentService (Move Fixed Location) ----------------
run FCa "F-C — FixLocationAssignmentService injects StockrecordService" \
    file_contains 'StockrecordService[[:space:]]+stockrecordService' "$FLA"
run FCb "F-C — recordRelocation called with CODE_MOVE_FIX_ASSIGNMENT" \
    file_contains_ml 'recordRelocation\([^;]*CODE_MOVE_FIX_ASSIGNMENT' "$FLA"

echo

# --- F-D — StockunitService (Move Stock whole-UL branch) ---------------------
run FDa "F-D — StockunitService injects StockrecordService" \
    file_contains 'StockrecordService[[:space:]]+stockrecordService' "$SUSVC"
run FDb "F-D — recordRelocation called with CODE_MANUAL_TRANSFER" \
    file_contains_ml 'recordRelocation\([^;]*CODE_MANUAL_TRANSFER' "$SUSVC"

echo

# --- Scope guard (NEGATIVE) — Option B must NOT be implemented ---------------
# processTransfer / UnitloadBusinessService must not log relocations (would flood
# stock history with shipping/putaway/BOL/truck moves). Comment-robust.
run NG1 "SCOPE — UnitloadBusinessService does NOT call recordRelocation" \
    code_not_contains 'recordRelocation' "$ULB"
run NG2 "SCOPE — UnitloadBusinessService does NOT reference stockrecordService" \
    code_not_contains 'stockrecordService' "$ULB"

echo

# --- Targeted tests (code-shape greps prove the call; tests prove it works) ---
mvn_test_passes() {
    mvn test -Dtest="$1" -DfailIfNoTests=false \
        -Dmaven.javadoc.skip=true -Djacoco.skip=true -Dcheckstyle.skip=true >/dev/null 2>&1
}
it_test_passes() {
    docker rm -f $(docker ps -aq --filter ancestor=postgres:12) >/dev/null 2>&1 || true
    mvn verify -Dit.test="$1" -Dtest=__NoSuchSurefireTest__ -DfailIfNoTests=false \
        -DargLine="-Dapi.version=1.41" \
        -Dmaven.javadoc.skip=true -Djacoco.skip=true -Dcheckstyle.skip=true >/dev/null 2>&1
}

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T-UT  "T — StockrecordServiceUnitTest passes"                 mvn_test_passes StockrecordServiceUnitTest
    run T-IT1 "T — FixLocationAssignmentServiceIT passes (failsafe)"  it_test_passes  FixLocationAssignmentServiceIT
    run T-IT2 "T — StockunitServiceIT passes (failsafe)"              it_test_passes  StockunitServiceIT
    run T-IT3 "T — StockRecordReportExclusionIT passes (failsafe)"    it_test_passes  StockRecordReportExclusionIT
else
    skip T-mvn "Targeted test runs" "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
