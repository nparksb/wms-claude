#!/usr/bin/env bash
# verify-SBDEV-1666-staging-transfer-lane-replenish-source-exclusion.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-1666-staging-transfer-lane-replenish-source-exclusion.md
#   "Exclude Staging & Transfer Lanes from Replenishment Sourcing" — v2/wms2-api
#
# PRE-IMPLEMENTATION BASELINE
# ---------------------------
# The feature is NOT yet implemented. POSITIVE code-shape checks (and the targeted
# unit-test rows) are EXPECTED TO FAIL today — that is the correct baseline. The
# implementing agent runs this after each pass and drives it to "0 fail".
# A "DONE" claim with any FAIL line is not accepted.
#
# NEGATIVE / preservation checks (destination isReplenishableArea untouched, no
# v1-style "source = N/A" branch, NO _excludingLanes twin for the HAL #2/#5
# queries, legacy source-query names preserved) are EXPECTED to PASS today.
#
# Run:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-1666-staging-transfer-lane-replenish-source-exclusion.sh
#   (set SKIP_MVN=1 to skip the targeted unit-test rows during code-shape iteration)
#
# Exit code is 0 iff all checks pass, non-zero otherwise.

set -u

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
        printf "  PASS  %-36s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-36s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    printf "  SKIP  %-36s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1))
}

# --- assertion helpers ---
file_contains()      { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains()  { ! grep -qE "$1" "$2" 2>/dev/null; }
# Multi-line variant — perl -0777 so the regex can span newlines.
file_contains_ml()   { PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null; }
# file_count_at_least <regex> <min> <file> — at least <min> matching lines
file_count_at_least(){ [ "$(grep -cE "$1" "$3" 2>/dev/null)" -ge "$2" ]; }
mvn_test_passes()    { mvn test -Dtest="$1" -DfailIfNoTests=false >/dev/null 2>&1; }

# --- target files (relative to WMS2_API_DIR) --- REPO PACKAGE IS repo/jpa (NOT repository)
SRC=src/main/java/net/aim_ai/wms
SVC=$SRC/service
REPO=$SRC/repo/jpa
UTIL=$SRC/util
CTRL=$SRC/controller

WC=$SVC/WmsConstants.java                                   # sysprop key                     [#13]
UTILF=$UTIL/LocationReplenishabilityUtil.java               # new isUsableSourceLocation + existing isReplenishableArea [#8,#17]
SUR=$REPO/StockunitRepository.java                          # source queries #1,#2,#3,#5
ULR=$REPO/UnitloadRepository.java                           # source query #4
FLR=$REPO/FixLocationAssignmentRepository.java              # shortage queries #6
IDR=$REPO/ItemdataRepository.java                           # shortage queries #7
RGS=$SVC/ReplenishGeneratorService.java                     # calculateOrder branch #7 (file-row) / #1 wiring
ROMS=$SVC/ReplenishmentOrderMaintenanceService.java         # isSourceUsable #9 / redirectSource #10
RSSS=$SVC/ReplenishmentOrderSourceSyncService.java          # syncForMovedStockUnit destination-lane guard #11
MOB=$SVC/mobile/MobileReplenishService.java                 # manual re-source lane check #12
MVR=$REPO/ReplenishmentMonitorViewRepository.java           # monitor view #14

# Canonical lane-guard SQL fragments (nullable-safe). Alias-agnostic where possible.
LANE_STAGING_NOTTRUE='staginglane\s+IS\s+NOT\s+TRUE'
LANE_TRANSFER_NOTTRUE='transferlane\s+IS\s+NOT\s+TRUE'
LANE_STAGING_ISTRUE='staginglane\s+IS\s+TRUE'
LANE_TRANSFER_ISTRUE='transferlane\s+IS\s+TRUE'
EXCLUDE_PARAM='excludeLanes'

# === Per-acceptance-item checks ==============================================

# A1. New activation sysprop key + default "false" (SBDEV-1762 precedent block).  [#13]
check_wmsconstants_key_present() {
    file_contains 'SYSTEM_PROPERTY_REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED_KEY\s*=' "$WC" \
    && file_contains_ml 'SYSTEM_PROPERTY_REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED_DEFAULT_VALUE\s*=\s*"false"' "$WC"
}

# A2. A service reads the toggle via getSysvalue(KEY).                            [#7,#8,#11,#12]
check_toggle_read_present() {
    file_contains 'SYSTEM_PROPERTY_REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED_KEY' "$RGS" \
    || file_contains 'SYSTEM_PROPERTY_REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED_KEY' "$ROMS"
}

# A3. New source-usability helper isUsableSourceLocation present.                 [#8]
check_helper_present() {
    file_contains 'isUsableSourceLocation' "$UTILF" \
    && file_contains 'getStaginglane|getTransferlane' "$UTILF"
}

# A4. Helper keys on the lane flags null-safely (Boolean.TRUE.equals(...getStaginglane)).  [#8]
#     Must be tied to the NEW lane-flag reads, not the pre-existing isReplenishableArea
#     use of Boolean.TRUE.equals on getUseforreplenish.
check_helper_flag_null_safe() {
    file_contains_ml 'Boolean\.TRUE\.equals\(\s*\w*\.?getStaginglane' "$UTILF" \
    || file_contains_ml 'Boolean\.TRUE\.equals\(\s*\w*\.?getTransferlane' "$UTILF"
}

# A5. NEGATIVE: destination isReplenishableArea preserved (still present, still
#     called at the untouched destination call-sites).                           [#17,#18]
check_isreplenishablearea_preserved() {
    file_contains 'isReplenishableArea' "$UTILF" \
    && file_contains 'isReplenishableArea' "$ROMS"
}

# A6. isSourceUsable gains the lane guard (routes via isUsableSourceLocation ON). [#9]
check_issourceusable_guarded() {
    file_contains 'isSourceUsable' "$ROMS" \
    && file_contains 'isUsableSourceLocation' "$ROMS"
}

# A7. syncForMovedStockUnit DESTINATION-lane guard: isReplenishableDestination
#     now inspects the lane flags on the destination.                            [#11]
check_syncmoved_destination_lane_guard() {
    file_contains 'isReplenishableDestination' "$RSSS" \
    && ( file_contains 'getStaginglane|getTransferlane' "$RSSS" \
         || ( file_contains "$LANE_STAGING_ISTRUE|staginglane" "$RSSS" ) )
}

# A7b. RSSS gained a SyspropService dependency (it had none before).             [#11]
check_rsss_syprop_injected() {
    file_contains 'SyspropService' "$RSSS" \
    && file_contains 'SYSTEM_PROPERTY_REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED_KEY' "$RSSS"
}

# A8. Monitor view: lane flags appear in BOTH the non-replenishable (IS TRUE) and
#     the replenishable (IS NOT TRUE) CASE branches — not merely "present".      [#14]
check_monitor_view_both_branches() {
    file_contains "$LANE_STAGING_ISTRUE" "$MVR" \
    && file_contains "$LANE_TRANSFER_ISTRUE" "$MVR" \
    && file_contains "$LANE_STAGING_NOTTRUE" "$MVR" \
    && file_contains "$LANE_TRANSFER_NOTTRUE" "$MVR"
}

# A9. GATED source queries (#1,#3) carry the parameterized lane guard.           [#1,#3]
check_stockunit_gated_guard() {
    file_contains "$EXCLUDE_PARAM" "$SUR" \
    && file_contains "$LANE_STAGING_NOTTRUE" "$SUR" \
    && file_contains "$LANE_TRANSFER_NOTTRUE" "$SUR"
}

# A9b. #1 gained @RestResource(exported=false) (was HAL-exported, cron-only).     [#1]
#      Order-INDEPENDENT: assert a single @RestResource(...) block for #1 contains
#      BOTH the method's rel/path token AND exported=false within the same parens
#      (either attribute order). Bounded to [^)] so it stays inside the annotation
#      and never spans the 800-char @Query body (fixes the append-order false-negative).
check_query1_exported_false() {
    file_contains 'getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage' "$SUR" \
    && ( file_contains_ml '@RestResource\([^)]*getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage[^)]*exported\s*=\s*false' "$SUR" \
      || file_contains_ml '@RestResource\([^)]*exported\s*=\s*false[^)]*getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage' "$SUR" )
}

# A10. UnitloadRepository source query (#4) carries the parameterized lane guard. [#4]
check_unitload_gated_guard() {
    file_contains "$EXCLUDE_PARAM" "$ULR" \
    && file_contains "$LANE_STAGING_NOTTRUE" "$ULR" \
    && file_contains "$LANE_TRANSFER_NOTTRUE" "$ULR"
}

# A11. Shortage-detection queries (#6,#7) carry the parameterized lane guard.     [#6,#7]
#      IDR has THREE useForReplenish EXISTS sites → the lane clause must appear
#      at least 3x: getIdsForItemDataWithoutFixedAssignment (value), ...Page (value),
#      and the ...Page countQuery's own EXISTS (Architect iter-2 finding). A 2-of-3
#      miss (typically the buried countQuery) MUST fail → count/page divergence when ON.
#      The countQuery-specific ml check pins the guard to the countQuery directly, not
#      just by arithmetic.
check_shortage_gated_guard() {
    ( file_contains "$EXCLUDE_PARAM" "$FLR" && file_contains "$LANE_STAGING_NOTTRUE" "$FLR" && file_contains "$LANE_TRANSFER_NOTTRUE" "$FLR" ) \
    && ( file_contains "$EXCLUDE_PARAM" "$IDR" \
         && file_count_at_least "$LANE_STAGING_NOTTRUE" 3 "$IDR" \
         && file_count_at_least "$LANE_TRANSFER_NOTTRUE" 3 "$IDR" \
         && file_contains_ml 'countQuery[\s\S]{0,2000}staginglane\s+IS\s+NOT\s+TRUE' "$IDR" )
}

# A12. MobileReplenishService:317 manual re-source path gains a lane check.       [#12]
check_mobile_manual_lane_guard() {
    file_contains 'getStaginglane|getTransferlane' "$MOB" \
    && file_contains 'SYSTEM_PROPERTY_REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED_KEY' "$MOB"
}

# A13. NEGATIVE: no v1-style "source = N/A"/last-resort branch was introduced.    [D1]
#      Literal "N/A" (slash required so it does not match "NA" inside DESTINATION),
#      plus the last-resort / not-applicable identifiers.
check_no_na_source_branch() {
    file_not_contains 'N/A|notApplicable|not_applicable|lastResort|last_resort' "$SUR" \
    && file_not_contains 'N/A|notApplicable|not_applicable|lastResort|last_resort' "$RGS"
}

# A14. UNCONDITIONAL HAL #2/#5: the two HAL-exposed open-request queries carry the
#      lane guard IN-BODY, and NO _excludingLanes twin was created for them.      [#2,#5]
#      (Positive part FAILS pre-impl; twin-absence part PASSES today.)
check_hal_unconditional_and_no_twin() {
    # in-body guard present for the HAL queries (guard lives beside their SELECTs)
    file_contains "$LANE_STAGING_NOTTRUE" "$SUR" \
    && file_contains "$LANE_TRANSFER_NOTTRUE" "$SUR" \
    && file_contains 'getStockUnitInfoForReplenishment' "$SUR" \
    && file_contains 'getStockUnitsForReplenishment' "$SUR" \
    && file_not_contains 'getStockUnitInfoForReplenishment_excludingLanes' "$SUR" \
    && file_not_contains 'getStockUnitsForReplenishment_excludingLanes' "$SUR"
}

# A15. NEGATIVE: HAL #2/#5 must NOT thread the excludeLanes param (they are
#      unconditional — see §3.2 gotcha). Assert neither method signature carries it.
check_hal_no_param() {
    file_not_contains 'getStockUnitInfoForReplenishment\([^)]*excludeLanes' "$SUR" \
    && file_not_contains 'getStockUnitsForReplenishment\([^)]*excludeLanes' "$SUR"
}

# A16. NEGATIVE: legacy source query name preserved (guard added in place, not renamed). [#1,AC6]
check_legacy_query_preserved() {
    file_contains 'getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage' "$SUR" \
    && file_contains 'getAvailableReplenishmentSources' "$SUR"
}

# === Runner ==================================================================

echo
echo "verify-SBDEV-1666 — staging/transfer-lane replenish-source exclusion acceptance checks"
echo "  WMS2_API_DIR=$WMS2_API_DIR"
echo "  REPO package = repo/jpa"
echo "  (pre-implementation: POSITIVE checks are EXPECTED to FAIL until the feature is built)"
echo

echo "-- sysprop key + toggle read --"
run A1  "WmsConstants activation key + default false"          check_wmsconstants_key_present
run A2  "service reads exclude-lanes toggle sysprop"           check_toggle_read_present
echo
echo "-- source-usability helper (new, source-only) --"
run A3  "isUsableSourceLocation helper present"                check_helper_present
run A4  "helper null-safe on lane flags (Boolean.TRUE.equals)" check_helper_flag_null_safe
run A5  "NEG: destination isReplenishableArea preserved"       check_isreplenishablearea_preserved
echo
echo "-- service mirror surfaces (SBDEV-2074 leak class) --"
run A6  "isSourceUsable routes via isUsableSourceLocation"     check_issourceusable_guarded
run A7  "syncForMovedStockUnit destination-lane guard"         check_syncmoved_destination_lane_guard
run A7b "RSSS gained SyspropService injection"                 check_rsss_syprop_injected
run A12 "MobileReplenishService:317 manual re-source lane guard" check_mobile_manual_lane_guard
echo
echo "-- GATED query guards (boolean-parameterized single query) --"
run A9  "StockunitRepository #1/#3 parameterized lane guard"   check_stockunit_gated_guard
run A9b "query #1 gained @RestResource(exported=false)"        check_query1_exported_false
run A10 "UnitloadRepository #4 parameterized lane guard"       check_unitload_gated_guard
run A11 "shortage-detection #6/#7 parameterized lane guard"    check_shortage_gated_guard
echo
echo "-- UNCONDITIONAL display corrections (no toggle, no twin) --"
run A14 "HAL #2/#5 guarded in-body + NO _excludingLanes twin"  check_hal_unconditional_and_no_twin
run A15 "NEG: HAL #2/#5 do NOT thread excludeLanes param"      check_hal_no_param
run A8  "monitor view lanes in BOTH non-repl + repl CASE"      check_monitor_view_both_branches
echo
echo "-- scope negatives / OFF-path preservation --"
run A13 "NEG: no v1-style source=N/A branch introduced"        check_no_na_source_branch
run A16 "NEG: legacy source query names preserved"             check_legacy_query_preserved
echo

# === Targeted unit tests (behavior, not just shape) ==========================
echo "-- targeted unit tests --"
if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T-GEN  "ReplenishGeneratorServiceUnitTest passes"           mvn_test_passes ReplenishGeneratorServiceUnitTest
    run T-MNT  "ReplenishmentOrderMaintenanceServiceUnitTest passes" mvn_test_passes ReplenishmentOrderMaintenanceServiceUnitTest
    run T-SYNC "ReplenishmentOrderSourceSyncServiceTest passes"     mvn_test_passes ReplenishmentOrderSourceSyncServiceTest
    run T-MOB  "MobileReplenishServiceUnitTest passes"              mvn_test_passes MobileReplenishServiceUnitTest
    run T-CTL  "ReplenishOrderControllerUnitTest passes"            mvn_test_passes ReplenishOrderControllerUnitTest
else
    skip T-mvn "Targeted unit-test runs" "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
