#!/usr/bin/env bash
# verify-SBDEV-2610-move-unitload-false-reserved-block.sh
# Machine-checkable acceptance for SBDEV-2610.
# Diagnosis (corrected after critic+architect): incident = SBDEV-2492 in-progress-replen
# block (ReplenishmentOrderSourceSyncService); checkReservedStock dead-end + orphan
# reconciliation is a separate latent hardening (Part 2).
#
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2610-move-unitload-false-reserved-block.sh
#
# Exit 0 iff all checks pass. Paste the final "Result:" line into the impl report.

set -u
PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v1/wms-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0
run() { local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi; }
skip() { printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }
file_contains()     { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }
mvn_test_passes()   { mvn test -Dtest="$1" -DfailIfNoTests=false -q 2>&1 | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0"; }

SRC=src/main/java/net/aim_ai/wms/service/ReplenishmentOrderSourceSyncService.java
MMU=src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java
MIG_GLOB="src/main/resources/db/migration/V1.26.3*__*reconcile*orphan*"
CALLBACK_GLOB="src/main/java/net/aim_ai/wms/**/V1_26_32*ReconcileOrphan*.java src/main/resources/db/callback/*ReconcileOrphan*.java"

# --- Part 1 / Fix A1: in-progress-replen block message is structured + names the order ---
check_A1_block_msg()   { file_contains 'complete or cancel' "$SRC"; }               # message kept + actionable
check_A1_order_ref()   { file_contains 'replenOrderNumber|getNumber\(\)' "$SRC"; }  # names the replen

# --- Part 2 / Fix B1: guard honesty (pick-state filter, no broadened lookup, recursion kept) ---
check_B1_pick_check()  { file_contains 'findByPickfromstockunitId' "$MMU"; }        # active-pick block added
check_B1_pick_state()  { grep -qE 'State\.(PICKED|FINISHED)|state *< *600' "$MMU"; } # pick-state filtered, not any-state
check_B1_recursion()   { file_contains 'findByCarrierunitloadId' "$MMU"; }          # child recursion preserved
check_B1_marker()      { file_contains 'SBDEV-2610' "$MMU"; }
check_B1_deadend_gone(){ file_not_contains 'Reserved stock! can not move unit load' "$MMU"; }
check_B1_no_broadened(){ file_not_contains 'findOpenSourceHolder' "$MMU"; }         # broadened lookup dropped (architect H2)

# --- Part 2 / Fix C1: reconciliation callback/migration exists w/ correct predicate ---
check_C1_exists()      { compgen -G "$MIG_GLOB" >/dev/null || compgen -G $CALLBACK_GLOB >/dev/null; }
check_C1_pick_table()  { grep -rqiE 'pickingorder_position|pickfromstockunit' $MIG_GLOB $CALLBACK_GLOB 2>/dev/null; }
check_C1_replen_guard(){ grep -rqiE 'state *< *700|State\.FINISHED' $MIG_GLOB $CALLBACK_GLOB 2>/dev/null; }

echo
echo "verify-SBDEV-2610 — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

echo "Part 1 — incident (in-progress replen block clarity):"
run A1a "A1 — block message present & actionable"           check_A1_block_msg
run A1b "A1 — message names the replen order"               check_A1_order_ref
echo
echo "Part 2 — latent guard-honesty + reconciliation:"
run B1a "B1 — guard checks picking positions"               check_B1_pick_check
run B1b "B1 — active-pick state filter (not any-state)"     check_B1_pick_state
run B1c "B1 — child-UL recursion preserved"                 check_B1_recursion
run B1d "B1 — stranded path marked (SBDEV-2610)"            check_B1_marker
run B1e "B1 — old dead-end throw removed"                   check_B1_deadend_gone
run B1f "B1 — broadened findOpenSourceHolder NOT added"     check_B1_no_broadened
run C1a "C1 — reconciliation migration/callback exists"     check_C1_exists
run C1b "C1 — uses pickingorder_position(pickfromstockunit)" check_C1_pick_table
run C1c "C1 — guards on open replen (state<700)"            check_C1_replen_guard
echo

if command -v mvn >/dev/null 2>&1; then
    run P1-test "ReplenishmentOrderSourceSyncServiceTest passes" mvn_test_passes ReplenishmentOrderSourceSyncServiceTest
    run P2-test "MobileMoveUnitloadServiceTest passes"           mvn_test_passes MobileMoveUnitloadServiceTest
else
    skip P1-test "ReplenishmentOrderSourceSyncServiceTest" "mvn not on PATH"
    skip P2-test "MobileMoveUnitloadServiceTest"           "mvn not on PATH"
fi

echo
echo "NOTE: 'Reserved stock!' dead-end removal (B1e) is Part 2; the INCIDENT fix is Part 1 (A1)."
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
