#!/usr/bin/env bash
# verify-SBDEV-2232-parcelmonitorview-palletise-toctou-lock-fix.sh
#
# Verifies implementation of SBDEV-2232: pessimistic locks on palletise /
# palletiseAndTruckLoad in ParcelMonitorViewService.
#
# Usage: bash sbdocs/9-System/scripts/verify-SBDEV-2232-parcelmonitorview-palletise-toctou-lock-fix.sh
# Exit: 0 = all PASS, 1 = one or more FAIL

set -euo pipefail

BASE="v2/wms2-api/src"
PMV="$BASE/main/java/net/aim_ai/wms/service/ParcelMonitorViewService.java"
ULB="$BASE/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java"
CO_REPO="$BASE/main/java/net/aim_ai/wms/repo/jpa/CustomerorderRepository.java"
UL_REPO="$BASE/main/java/net/aim_ai/wms/repo/jpa/UnitloadRepository.java"
BOL_REPO="$BASE/main/java/net/aim_ai/wms/repo/jpa/BillofladingRepository.java"
UNIT_TEST="$BASE/test/java/net/aim_ai/wms/unit/service/ParcelMonitorViewServiceUnitTest.java"
IT_TEST="$BASE/test/java/net/aim_ai/wms/integration/service/ParcelMonitorViewServiceConcurrencyIT.java"

PASS=0
FAIL=0

pass() { echo "PASS [$1]"; PASS=$((PASS + 1)); }
fail() { echo "FAIL [$1] — $2"; FAIL=$((FAIL + 1)); }

file_exists()      { [ -f "$1" ]; }
file_contains()    { grep -qE "$2" "$1"; }
file_contains_n_times() {
    local pattern="$1" file="$2" expected="$3"
    local count
    count=$(grep -cE "$pattern" "$file" 2>/dev/null || true)
    [ "$count" -ge "$expected" ]
}
file_not_contains() { ! grep -qE "$2" "$1"; }

# ──────────────────────────────────────────────────────────────
# Fix A — Repository prerequisites
# ──────────────────────────────────────────────────────────────

check_FA1_customerorder_findByIdForUpdate() {
    file_exists "$CO_REPO" && file_contains "$CO_REPO" 'findByIdForUpdate'
}
check_FA1_customerorder_findByIdForUpdate \
    && pass "FA-1 CustomerorderRepository.findByIdForUpdate present" \
    || fail "FA-1" "CustomerorderRepository.findByIdForUpdate missing in $CO_REPO"

check_FA2_unitload_findByIdForUpdate() {
    file_exists "$UL_REPO" && file_contains "$UL_REPO" 'findByIdForUpdate'
}
check_FA2_unitload_findByIdForUpdate \
    && pass "FA-2 UnitloadRepository.findByIdForUpdate present" \
    || fail "FA-2" "UnitloadRepository.findByIdForUpdate missing in $UL_REPO"

check_FA3_billoflading_findByIdForUpdate() {
    file_exists "$BOL_REPO" && file_contains "$BOL_REPO" 'findByIdForUpdate'
}
check_FA3_billoflading_findByIdForUpdate \
    && pass "FA-3 BillofladingRepository.findByIdForUpdate present" \
    || fail "FA-3" "BillofladingRepository.findByIdForUpdate missing in $BOL_REPO"

# ──────────────────────────────────────────────────────────────
# Fix D — BOL locked FIRST in palletiseAndTruckLoad
# ──────────────────────────────────────────────────────────────

check_FD1_bol_locked() {
    file_exists "$PMV" && file_contains "$PMV" 'billofladingRepository\.findByIdForUpdate'
}
check_FD1_bol_locked \
    && pass "FD-1 billofladingRepository.findByIdForUpdate called in ParcelMonitorViewService" \
    || fail "FD-1" "billofladingRepository.findByIdForUpdate not found in $PMV"

check_FD2_bol_state_revalidated() {
    file_exists "$PMV" && \
    file_contains "$PMV" 'BillOfLadingState\.CLOSED' && \
    file_contains "$PMV" 'BillOfLadingState\.CANCELLED'
}
check_FD2_bol_state_revalidated \
    && pass "FD-2 BOL state re-validated against CLOSED/CANCELLED under lock" \
    || fail "FD-2" "BOL CLOSED/CANCELLED guard missing after findByIdForUpdate in $PMV"

check_FD3_bol_lock_before_state_switch() {
    local lock_line switch_line
    lock_line=$(grep -nE 'billofladingRepository\.findByIdForUpdate' "$PMV" 2>/dev/null | head -1 | cut -d: -f1)
    switch_line=$(grep -nE 'switch\s*\(\s*(bolState|lockedBOL\.getState\(\)|billOfLading\.getState\(\))' "$PMV" 2>/dev/null | head -1 | cut -d: -f1)
    [ -n "$lock_line" ] && [ -n "$switch_line" ] && [ "$lock_line" -lt "$switch_line" ]
}
check_FD3_bol_lock_before_state_switch \
    && pass "FD-3 BOL findByIdForUpdate appears before state switch (correct ordering)" \
    || fail "FD-3" "BOL findByIdForUpdate must appear BEFORE the state switch in $PMV"

# ──────────────────────────────────────────────────────────────
# Fix B — Customer orders sorted + locked
# ──────────────────────────────────────────────────────────────

check_FB1_sort_before_lock() {
    file_exists "$PMV" && \
    file_contains "$PMV" 'Comparator\.comparing\(Customerorder::getId\)'
}
check_FB1_sort_before_lock \
    && pass "FB-1 Customerorder list sorted by ID before lock loop" \
    || fail "FB-1" "Comparator.comparing(Customerorder::getId) not found in $PMV"

check_FB2_customerorder_findByIdForUpdate() {
    file_exists "$PMV" && \
    file_contains "$PMV" 'customerorderRepository\.findByIdForUpdate'
}
check_FB2_customerorder_findByIdForUpdate \
    && pass "FB-2 customerorderRepository.findByIdForUpdate called inside palletise/palletiseAndTruckLoad" \
    || fail "FB-2" "customerorderRepository.findByIdForUpdate not found in $PMV"

check_FB_NEG1_findByExternalIdList_not_mutated_directly() {
    # The old pattern was to mutate the stale list returned by findByExternalIdList.
    # After fix, findByExternalIdList result is only used for ID discovery (wrapped in new ArrayList).
    # We check that a defensive copy (new ArrayList) is used around findByExternalIdList.
    file_exists "$PMV" && \
    file_contains "$PMV" 'new ArrayList.*findByExternalIdList'
}
check_FB_NEG1_findByExternalIdList_not_mutated_directly \
    && pass "FB-NEG-1 Defensive copy (new ArrayList) wraps findByExternalIdList result" \
    || fail "FB-NEG-1" "Missing: new ArrayList<>(...findByExternalIdList(...)) defensive copy in $PMV"

# ──────────────────────────────────────────────────────────────
# Fix C — Parcel unitload locked before transferUnitLoadToCarrier
# ──────────────────────────────────────────────────────────────

check_FC1_parcel_locked() {
    file_exists "$PMV" && \
    file_contains "$PMV" 'unitloadRepository\.findByIdForUpdate'
}
check_FC1_parcel_locked \
    && pass "FC-1 unitloadRepository.findByIdForUpdate called for parcel/pallet locking" \
    || fail "FC-1" "unitloadRepository.findByIdForUpdate not found in $PMV"

check_FC_NEG1_old_findById_for_parcel_gone() {
    # After fix, unitloadRepository.findById(customerOrder.getParcelId()) must not appear.
    # The locked pattern uses findByIdForUpdate for parcel reads.
    file_exists "$PMV" && \
    file_not_contains "$PMV" 'unitloadRepository\.findById\(customerOrder\.getParcelId\(\)\)'
}
check_FC_NEG1_old_findById_for_parcel_gone \
    && pass "FC-NEG-1 Old unitloadRepository.findById(customerOrder.getParcelId()) removed" \
    || fail "FC-NEG-1" "Stale unitloadRepository.findById(customerOrder.getParcelId()) still present in $PMV"

# ──────────────────────────────────────────────────────────────
# Fix E — Pallet unitload locked
# ──────────────────────────────────────────────────────────────

check_FE1_pallet_locked_both_methods() {
    # unitloadRepository.findByIdForUpdate must appear at least twice:
    # once for the pallet in palletise, once for the pallet in palletiseAndTruckLoad,
    # plus additional occurrences for parcels. Overall ≥ 2 occurrences expected.
    file_exists "$PMV" && \
    file_contains_n_times 'unitloadRepository\.findByIdForUpdate' "$PMV" 2
}
check_FE1_pallet_locked_both_methods \
    && pass "FE-1 unitloadRepository.findByIdForUpdate appears ≥2 times (pallet + parcel coverage)" \
    || fail "FE-1" "unitloadRepository.findByIdForUpdate appears fewer than 2 times in $PMV"

check_FE_NEG1_existing_pallet_revalidated_in_palletise() {
    # Fix E: existing-pallet branch in palletise must have a CarrierUnitloadId null-check under lock.
    file_exists "$PMV" && \
    file_contains "$PMV" 'getCarrierunitloadId.*null|null.*getCarrierunitloadId'
}
check_FE_NEG1_existing_pallet_revalidated_in_palletise \
    && pass "FE-NEG-1 Existing-pallet carrierunitloadId re-validation present in palletise" \
    || fail "FE-NEG-1" "Pallet carrierunitloadId null-check under lock missing from $PMV"

check_FE2_pallet_already_loaded_throws() {
    file_exists "$PMV" && \
    file_contains "$PMV" 'Pallet already loaded'
}
check_FE2_pallet_already_loaded_throws \
    && pass "FE-2 'Pallet already loaded' BusinessException thrown from locked re-validation" \
    || fail "FE-2" "'Pallet already loaded' BusinessException not found in $PMV"

# ──────────────────────────────────────────────────────────────
# Lock order comments (R4, AC5, AC8)
# ──────────────────────────────────────────────────────────────

check_LO1_lock_order_comment_in_both_methods() {
    file_exists "$PMV" && \
    file_contains_n_times '// Lock acquisition order' "$PMV" 2
}
check_LO1_lock_order_comment_in_both_methods \
    && pass "LO-1 'Lock acquisition order' comment present in both method bodies" \
    || fail "LO-1" "Expect '// Lock acquisition order' comment in BOTH palletise AND palletiseAndTruckLoad in $PMV"

# ──────────────────────────────────────────────────────────────
# entityManager.refresh() not added (Architect R2 — must be absent)
# ──────────────────────────────────────────────────────────────

check_EM1_no_entitymanager_refresh() {
    file_exists "$PMV" && \
    file_not_contains "$PMV" 'entityManager\.refresh\|em\.refresh'
}
check_EM1_no_entitymanager_refresh \
    && pass "EM-1 entityManager.refresh() not added (findByIdForUpdate returns DB-fresh state)" \
    || fail "EM-1" "Redundant entityManager.refresh() found in $PMV — remove it"

# ──────────────────────────────────────────────────────────────
# Observability — LOG.warn on state-advance-under-lock (R9, AC9)
# ──────────────────────────────────────────────────────────────

check_R9_log_warn_state_advanced() {
    file_exists "$PMV" && \
    file_contains "$PMV" 'LOG\.warn.*state advanced.*under lock|state advanced.*under lock.*LOG\.warn'
}
check_R9_log_warn_state_advanced \
    && pass "R9-1 LOG.warn emitted when customer-order state advances under lock" \
    || fail "R9-1" "Missing LOG.warn(\"state advanced under lock\") in $PMV"

# ──────────────────────────────────────────────────────────────
# UnitloadBusinessService — caller-lock invariant comment corrected (R3)
# ──────────────────────────────────────────────────────────────

check_R3_transferUnitLoadToCarrier_comment_corrected() {
    file_exists "$ULB" && \
    file_contains "$ULB" 'CALLER MUST HOLD ROW LOCKS|lock must be held by caller'
}
check_R3_transferUnitLoadToCarrier_comment_corrected \
    && pass "R3-1 Caller-lock invariant comment present in UnitloadBusinessService.transferUnitLoadToCarrier" \
    || fail "R3-1" "Missing 'CALLER MUST HOLD ROW LOCKS' / 'lock must be held by caller' comment in $ULB"

# ──────────────────────────────────────────────────────────────
# Test files present
# ──────────────────────────────────────────────────────────────

check_UT1_unit_test_exists_and_has_findByIdForUpdate_verify() {
    file_exists "$UNIT_TEST" && \
    file_contains "$UNIT_TEST" 'findByIdForUpdate'
}
check_UT1_unit_test_exists_and_has_findByIdForUpdate_verify \
    && pass "UT-1 ParcelMonitorViewServiceUnitTest exists and verifies findByIdForUpdate calls" \
    || fail "UT-1" "ParcelMonitorViewServiceUnitTest missing or lacks findByIdForUpdate verify in $UNIT_TEST"

check_IT1_concurrency_it_exists() {
    file_exists "$IT_TEST"
}
check_IT1_concurrency_it_exists \
    && pass "IT-1 ParcelMonitorViewServiceConcurrencyIT exists" \
    || fail "IT-1" "ParcelMonitorViewServiceConcurrencyIT not found at $IT_TEST"

# ──────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS PASS, $FAIL FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
