#!/usr/bin/env bash
# verify-SBDEV-2001-empty-pallet-misrouted-to-nirvana.sh
#
# Acceptance for SBDEV-2001-empty-pallet-misrouted-to-nirvana.md (v2/wms2-api).
#
# Fix A: new UnitloadBusinessService.relocateEmptiedContainer(...) — type-aware relocation.
# Fix B: StockunitBusinessService:366,386 repointed sendToNirvana -> relocateEmptiedContainer.
# Fix C: PickingorderBusinessService:559 repointed sendToNirvana -> relocateEmptiedContainer.
# Guard: the 9 deliberate-delete callsites STILL call sendToNirvana (must not be touched).
#
# Run after every implementation pass:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2001-empty-pallet-misrouted-to-nirvana.sh
#   (set SKIP_MVN=1 to skip the targeted unit-test runs)

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}
skip() { printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

file_contains()     { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { ! grep -qE "$1" "$2" 2>/dev/null; }
file_contains_ml()  { PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null; }
# count occurrences of a pattern in a file, assert == N
count_eq() { local n; n=$(grep -cE "$1" "$2" 2>/dev/null); [ "$n" = "$3" ]; }

SVC=src/main/java/net/aim_ai/wms/service

ULB=$SVC/UnitloadBusinessService.java
SUB=$SVC/StockunitBusinessService.java
POB=$SVC/PickingorderBusinessService.java
GRP=$SVC/GoodsReceiptPositionService.java
FLA=$SVC/FixLocationAssignmentService.java
ULS=$SVC/UnitloadService.java
BOL=$SVC/BillofladingService.java
CYC=$SVC/mobile/MobileCycleCountService.java
COS=$SVC/CustomerorderService.java
MMU=$SVC/mobile/MobileMoveUnitloadService.java
WMC=$SVC/WmsConstants.java

echo
echo "verify-SBDEV-2001 — empty-pallet misrouting acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# --- Fix A — new relocateEmptiedContainer method -----------------------------
run A1 "Fix A — relocateEmptiedContainer(...) method declared" \
    file_contains 'void\s+relocateEmptiedContainer\s*\(' "$ULB"
run A2 "Fix A — Pallet/Cart branch targets EmptyPallets" \
    file_contains_ml 'UNIT_LOAD_TYPE_PALLET.*\n?.*UNIT_LOAD_TYPE_CART|UNIT_LOAD_TYPE_CART.*\n?.*UNIT_LOAD_TYPE_PALLET' "$ULB"
run A3 "Fix A — references STORAGE_LOCATION_EMPTY_PALLETS" \
    file_contains 'STORAGE_LOCATION_EMPTY_PALLETS' "$ULB"
run A4 "Fix A — Tote branch references STORAGE_LOCATION_EMPTY_TOTES" \
    file_contains 'STORAGE_LOCATION_EMPTY_TOTES' "$ULB"
run A5 "Fix A — non-reusable default branch delegates to sendToNirvana" \
    file_contains_ml 'default:[\s\S]*?sendToNirvana\(' "$ULB"
run A6 "Fix A — emptiness guards present (has stock / is carrier)" \
    file_contains_ml 'relocateEmptiedContainer[\s\S]*findByCarrierunitloadId' "$ULB"
run A7 "Fix A — relocate branch does NOT set GOING_TO_DELETE (no mangle) — method keeps label intact" \
    bash -c '
      awk "/void relocateEmptiedContainer/{f=1} f{print} f&&/^    }/{exit}" '"$ULB"' \
        | grep -qE "GOING_TO_DELETE|-X-" && exit 1 || exit 0'
run A8 "Fix A/D1 — relocate branch clears lock to NOT_LOCKED" \
    file_contains_ml 'relocateEmptiedContainer[\s\S]*setEntityLock\([^)]*NOT_LOCKED' "$ULB"
run A9 "Fix A/D2 — relocate records CODE_CONTAINER_RELOCATED_EMPTYPOOL (not SEND_TO_NIRVANA)" \
    file_contains_ml 'relocateEmptiedContainer[\s\S]*CODE_CONTAINER_RELOCATED_EMPTYPOOL' "$ULB"
run A10 "Fix A/D2 — new activity code constant declared in WmsConstants" \
    file_contains 'CODE_CONTAINER_RELOCATED_EMPTYPOOL\s*=' "$WMC"

echo

# --- Fix B — shared-method depletion branch (propagates to all 15 §0.A callers)
run B1 "Fix B — StockunitBusinessService calls relocateEmptiedContainer twice" \
    count_eq 'relocateEmptiedContainer\(' "$SUB" 2
run B2 "Fix B — no unitloadBusinessService.sendToNirvana(...) remains in StockunitBusinessService" \
    file_not_contains 'unitloadBusinessService\.sendToNirvana\(' "$SUB"

echo

# --- Fix C — PickingorderBusinessService carrier branch -----------------------
run C1 "Fix C — PickingorderBusinessService calls relocateEmptiedContainer" \
    file_contains 'relocateEmptiedContainer\(\s*pallet' "$POB"
run C2 "Fix C — old sendToNirvana(pallet,...) carrier call is gone" \
    file_not_contains 'sendToNirvana\(\s*pallet' "$POB"

echo

# --- Fix D — combineStock sibling consistency ---------------------------------
run D1 "Fix D — BillofladingService relocates emptyUnitLoadList via relocateEmptiedContainer" \
    file_contains 'relocateEmptiedContainer\(' "$BOL"
run D2 "Fix D — combineStock no longer retires emptyUnitLoadList via sendToNirvana" \
    file_not_contains 'unitloadBusinessService\.sendToNirvana\(' "$BOL"

echo

# --- Guard — deliberate-delete callsites MUST still retire via sendToNirvana ---
# (BillofladingService intentionally REMOVED from this set — it is now in-scope via Fix D.)
run G1 "Guard — GoodsReceiptPositionService still calls sendToNirvana" \
    file_contains 'sendToNirvana\(' "$GRP"
run G2 "Guard — FixLocationAssignmentService still calls sendToNirvana" \
    file_contains 'sendToNirvana\(' "$FLA"
run G3 "Guard — UnitloadService still calls sendToNirvana" \
    file_contains 'sendToNirvana\(' "$ULS"
run G4 "Guard — MobileCycleCountService still calls sendToNirvana" \
    file_contains 'sendToNirvana\(' "$CYC"
run G5 "Guard — CustomerorderService still calls sendToNirvana" \
    file_contains 'sendToNirvana\(' "$COS"
run G6 "Guard — MobileMoveUnitloadService (explicit user move-to-nirvana) still calls sendToNirvana" \
    file_contains 'sendToNirvana\(' "$MMU"

echo

# --- Targeted unit tests ------------------------------------------------------
mvn_test_passes() { mvn test -Dtest="$1" -DfailIfNoTests=false >/dev/null 2>&1; }

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T-ULB "T — UnitloadBusinessServiceUnitTest passes" mvn_test_passes UnitloadBusinessServiceUnitTest
    run T-SUB "T — StockunitBusinessServiceUnitTest passes" mvn_test_passes StockunitBusinessServiceUnitTest
    run T-POB "T — PickingorderBusinessServiceUnitTest passes" mvn_test_passes PickingorderBusinessServiceUnitTest
    run T-BOL "T — BillofladingServiceUnitTest passes" mvn_test_passes BillofladingServiceUnitTest
    run T-CLB "T — ClubLineOrderProcessorUnitTest passes" mvn_test_passes ClubLineOrderProcessorUnitTest
    run T-SUS "T — StockunitServiceUnitTest passes (split depletion relocates)" mvn_test_passes StockunitServiceUnitTest
else
    skip T-mvn "Targeted unit-test runs" "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
