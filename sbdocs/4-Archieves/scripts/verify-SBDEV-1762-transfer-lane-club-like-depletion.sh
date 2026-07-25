#!/usr/bin/env bash
# verify-SBDEV-1762-transfer-lane-club-like-depletion.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-1762-transfer-lane-club-like-depletion.md
#   "Make Transfer Lanes Function Like Club Lanes (selective partial depletion)" — v2/wms2-api
#
# PRE-IMPLEMENTATION BASELINE
# ---------------------------
# The feature is NOT yet implemented. Therefore the POSITIVE code-shape checks
# (and all three targeted unit-test rows) are EXPECTED TO FAIL when this script
# is run today — that is the correct baseline. The implementing agent runs this
# script after each pass and drives it to "0 fail". A "DONE" claim with any FAIL
# line is not accepted.
#
# The NEGATIVE / preservation checks (no getStockunits(), no up-front lane lock,
# OFF-branch intact, primitive untouched) are expected to PASS today because they
# encode the byte-identical / do-not-regress guarantees.
#
# Run:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-1762-transfer-lane-club-like-depletion.sh
#   (set SKIP_MVN=1 to skip the targeted unit-test rows during code-shape iteration)
#
# Exit code is 0 iff all checks pass, non-zero otherwise.

set -u

# Root at the v2/wms2-api repo; override with WMS2_API_DIR=... if your checkout differs.
WMS2_API_DIR="${WMS2_API_DIR:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$WMS2_API_DIR" || { echo "FATAL: WMS2_API_DIR=$WMS2_API_DIR not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

# run <id> <description> <command...>  — exit 0 -> PASS, non-zero -> FAIL
run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-32s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-32s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    printf "  SKIP  %-32s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1))
}

# --- assertion helpers ---
file_contains()      { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains()  { ! grep -qE "$1" "$2" 2>/dev/null; }
# Multi-line variant — perl -0777 so the regex can span newlines.
file_contains_ml()   { PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null; }
# A maven test class exists and currently passes (trust mvn's exit code).
mvn_test_passes()    { mvn test -Dtest="$1" -DfailIfNoTests=false >/dev/null 2>&1; }

# --- target files (relative to WMS2_API_DIR) ---
SVC=src/main/java/net/aim_ai/wms/service

BOL=$SVC/BillofladingService.java        # transferOrder + combineStock
TOS=$SVC/TransferOrderService.java       # isEnoughStockOnTransferLane gate + overload
SBS=$SVC/StockunitBusinessService.java   # transferStockToUnitLoad split primitive (must stay unchanged)
WC=$SVC/WmsConstants.java                # SYSTEM_PROPERTY_* activation keys

# === Per-acceptance-item checks ==============================================

# 1. New activation sysprop key + default "false" in WmsConstants.
check_wmsconstants_key_present() {
    file_contains 'SYSTEM_PROPERTY_TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED_KEY\s*=' "$WC" \
    && file_contains_ml 'SYSTEM_PROPERTY_TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED_DEFAULT_VALUE\s*=\s*"false"' "$WC"
}

# 2. transferOrder reads the toggle via Boolean.parseBoolean(getSysvalue(KEY)).
check_toggle_read_present() {
    file_contains 'Boolean\.parseBoolean' "$BOL" \
    && file_contains_ml 'getSysvalue\(\s*WmsConstants\.SYSTEM_PROPERTY_TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED_KEY' "$BOL"
}

# 3. combineStock signature carries the Map<Long,BigDecimal> needed budget param.
check_combinestock_budget_param() {
    file_contains 'Map<Long,\s*BigDecimal>\s+needed' "$BOL"
}

# 4. OFF branch preserved: whole-amount transfer + CODE_TRANSFER_BUILD_TRUCK,
#    plus the lane sweep + emptied-container relocation still present (byte-identical OFF).
check_off_branch_intact() {
    file_contains 'CODE_TRANSFER_BUILD_TRUCK' "$BOL" \
    && file_contains 'findByStoragelocationId' "$BOL" \
    && file_contains 'relocateEmptiedContainer' "$BOL" \
    && file_contains 'getAmount\(\)' "$BOL"
}

# 5. NEGATIVE: no ul.getStockunits() introduced (Unitload has no @OneToMany).
check_no_getstockunits() {
    file_not_contains 'getStockunits\(' "$BOL"
}

# 6. NEGATIVE (v4): the inverting up-front lane-Location lock must NOT be reintroduced.
check_no_upfront_location_lock() {
    file_not_contains 'locationRepository\.findByIdForUpdate' "$BOL"
}

# 7. ON: lane UL list sorted by id (deterministic acquisition order).
check_lane_ul_sorted_on() {
    file_contains 'Comparator\.comparing\(Unitload::getId\)' "$BOL"
}

# 8. ON: leaf stockunit list sorted by id inside combineStock.
check_su_sorted_on() {
    file_contains 'Comparator\.comparing\(Stockunit::getId\)' "$BOL"
}

# 9. ON gate + depletion use reserved-adjusted availability (amount - reservedamount).
check_reserved_adjusted_gate() {
    file_contains 'getReservedamount' "$TOS"
}

# 10. New gate overload isEnoughStockOnTransferLane(Customerorder, boolean).
check_gate_overload() {
    file_contains 'isEnoughStockOnTransferLane\([^)]*boolean' "$TOS"
}

# 11. OFF-only reject branches ("too much" + foreign SKU) guarded behind !partial.
check_gate_off_branches_guarded() {
    file_contains '!\s*partial' "$TOS"
}

# 12. Fail-loud post-loop under-delivery assertion in the ON path.
check_fail_loud_assertion() {
    file_contains 'under-delivered' "$BOL"
}

# 13. NEGATIVE: shared primitive present/unchanged — canonical SU->UL->Location
#     lock order must not be reordered by this ticket (presence/shape proxy).
check_primitive_untouched() {
    file_contains 'transferStockToUnitLoad' "$SBS"
}

# === Runner ==================================================================

echo
echo "verify-SBDEV-1762 — transfer-lane club-like depletion acceptance checks"
echo "  WMS2_API_DIR=$WMS2_API_DIR"
echo "  (pre-implementation: POSITIVE checks are EXPECTED to FAIL until the feature is built)"
echo

echo "-- WmsConstants + toggle read --"
run A1  "WmsConstants activation key + default false"      check_wmsconstants_key_present
run A2  "transferOrder reads toggle sysprop"               check_toggle_read_present
echo
echo "-- combineStock parameterization + OFF preservation --"
run A3  "combineStock carries Map needed budget param"     check_combinestock_budget_param
run A4  "OFF branch intact (whole-amt sweep + relocate)"   check_off_branch_intact
run A5  "NEG: no ul.getStockunits() introduced"            check_no_getstockunits
echo
echo "-- concurrency posture (v4: canonical SU-first, no up-front lock) --"
run A6  "NEG: no up-front lane-Location lock"              check_no_upfront_location_lock
run A7  "ON: lane UL sorted by Unitload::getId"            check_lane_ul_sorted_on
run A8  "ON: leaf SU sorted by Stockunit::getId"           check_su_sorted_on
echo
echo "-- gate overload (reserved-adjusted, toggle-guarded) --"
run A9  "ON gate reserved-adjusted (getReservedamount)"    check_reserved_adjusted_gate
run A10 "gate overload (Customerorder, boolean)"           check_gate_overload
run A11 "OFF-only branches guarded behind !partial"        check_gate_off_branches_guarded
echo
echo "-- fail-loud + primitive untouched --"
run A12 "ON fail-loud under-delivery assertion"            check_fail_loud_assertion
run A13 "NEG: transferStockToUnitLoad primitive present"   check_primitive_untouched
echo

# === Targeted unit tests (behavior, not just shape) ==========================
echo "-- targeted unit tests --"
if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T-BOL  "BillofladingServiceUnitTest passes"       mvn_test_passes BillofladingServiceUnitTest
    run T-TOS  "TransferOrderServiceUnitTest passes"      mvn_test_passes TransferOrderServiceUnitTest
    run T-CTRL "TransfersControllerUnitTest passes"       mvn_test_passes TransfersControllerUnitTest
else
    skip T-mvn "Targeted unit-test runs" "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
