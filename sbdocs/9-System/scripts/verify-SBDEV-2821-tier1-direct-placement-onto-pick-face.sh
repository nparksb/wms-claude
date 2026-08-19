#!/usr/bin/env bash
# verify-SBDEV-2821-tier1-direct-placement-onto-pick-face.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2821-tier1-direct-placement-onto-pick-face.md
#
# Usage:
#   bash sbdocs/9-System/scripts/verify-SBDEV-2821-tier1-direct-placement-onto-pick-face.sh
#   PROJECT_ROOT=<symlink-shadow-root> bash ...
#
# ⚠ PROJECT_ROOT MUST point at a shadow root whose v2/wms2-api symlinks to the
# worktree, or this grades the MAIN CHECKOUT and is blind to the work. Always
# state which root a reported Result: line came from.
#
# API-only. Option (iii) touches no UI, and §5.2 step 5 (mobile UI) is DEFERRED
# pending §10 Q13, so there are deliberately no UI rows.
#
# ---------------------------------------------------------------------------
# NEGATIVE-TEST THIS SCRIPT BEFORE TRUSTING IT.
# Rows are split into two classes and they behave DIFFERENTLY pre-fix:
#
#   FIX rows   (A1 A2 A3 A5 A6 B1 B2 B3 C1 C2 C4 C5 C6 T1 T2 T3 T4 T5)
#              MUST ALL FAIL on untouched origin/develop. A FIX row that passes
#              pre-fix is vacuous and must be rewritten as a call-site regex.
#              VERIFIED 2026-08-09 against origin/develop @ 7d9d38e: all 18 FAIL
#              (pre-fix 6 pass / 18 fail  ->  post-fix 24 pass / 0 fail).
#   GUARD rows (A4 C3 D1 D2 D3 D4)
#              Assert an ABSENCE or a NON-change, so they are green on both
#              sides by design. They are not evidence the fix landed; they are
#              evidence it did not overreach. Never count them toward "the fix
#              is proven".
#
# (Real incident this guards: SBDEV-2736 scored 57 pass / 0 fail on the very
# build that still contained the defect the ticket was written to catch.)
#
# LANDMINES guarded below, all previously bitten in this repo:
#  1. perl -0777 -ne FAILS OPEN — exits 0 when it cannot open the file, so every
#     multi-line assertion about a new/missing file false-greens. Every helper
#     starts with an explicit [ -f ] guard.
#  2. Interpolating a pattern into /.../ breaks on any '/' in the pattern, which
#     FALSE-REDS. Patterns are passed through the environment instead.
#  3. A row naming an undefined function records bash's 127 as a plain FAIL,
#     indistinguishable from unimplemented work. Every helper used below is
#     defined above its first use; `bash -n` alone does not catch this.
# ---------------------------------------------------------------------------

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"

[ -d "$PROJECT_ROOT" ] || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }
cd "$PROJECT_ROOT" || { echo "FATAL: cannot cd to PROJECT_ROOT=$PROJECT_ROOT"; exit 2; }

PASS=0; FAIL=0; SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-8s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-8s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    local id=$1 desc=$2 reason=$3
    printf "  SKIP  %-8s  %s  (%s)\n" "$id" "$desc" "$reason"; SKIP=$((SKIP+1))
}

run_mvn() {
    local id=$1 desc=$2; shift 2
    if ! command -v mvn >/dev/null 2>&1; then
        skip "$id" "$desc" "mvn not on PATH (SDKMAN export needed)"; return
    fi
    run "$id" "$desc" "$@"
}

# --- assertion helpers (every one guards file existence FIRST) ---------------

file_contains()     { [ -f "$2" ] || return 1; grep -qE "$1" "$2"; }
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }

file_contains_ml() {
    [ -f "$2" ] || return 1
    VERIFY_PAT="$1" perl -0777 -ne 'exit($_ =~ /$ENV{VERIFY_PAT}/s ? 0 : 1)' "$2"
}

file_not_contains_ml() {
    [ -f "$2" ] || return 1
    VERIFY_PAT="$1" perl -0777 -ne 'exit($_ =~ /$ENV{VERIFY_PAT}/s ? 1 : 0)' "$2"
}

# Extract one Java method body by name (method start -> next line that is
# exactly 4-space-indented "}"), so a claim about storeBoxOnLocation cannot be
# satisfied by calculatePutAwayList and vice versa.
java_method() {
    [ -f "$1" ] || return 1
    awk "/(public|private|protected|static).*[ ]$2\\(/,/^    \\}\$/" "$1"
}

method_contains() {
    local file=$1 method=$2 pat=$3
    [ -f "$file" ] || return 1
    java_method "$file" "$method" | grep -qE "$pat"
}

method_not_contains() {
    local file=$1 method=$2 pat=$3
    [ -f "$file" ] || return 1
    ! java_method "$file" "$method" | grep -qE "$pat"
}

tree_not_contains() {
    # absence across the whole main source tree
    ! grep -rqE "$1" src/main/java 2>/dev/null
}

mvn_test_passes() {
    mvn test -Dtest="$1" -DfailIfNoTests=false -DfailIfNoSpecifiedTests=false -q >/dev/null 2>&1
}

# Defined as a FUNCTION, not inlined into `bash -c` — a helper invoked inside a
# subshell is undefined there, and bash's 127 is recorded by run() as a plain
# FAIL, indistinguishable from unimplemented work (landmine 3 above).
# T5 must not be satisfiable by a tree that simply HAS NO gate tests — on
# untouched develop "both classes pass" is trivially true, which is the exact
# false-green this script exists to prevent. Require the RED methods to be
# present FIRST, then require the suite to be green.
red_tests_present_and_green() {
    file_contains 'shouldOfferConfiguredFlowbinWhenSkuHasNoStockAnywhere' "$TEST" \
        && file_contains 'shouldOfferConfiguredCasesAndPalletsLocation' "$TEST" \
        && file_contains 'casesAndPalletsDestinationShouldPlaceWithoutCreatingFixLocationAssignment' "$TEST" \
        && mvn_test_passes 'MobilePutAwayServiceUnitTest,ReceivingServiceUnitTest'
}

all_guards_present() {
    file_contains 'flowbinDestinationShouldMergeIntoResidentUnitLoad' "$TEST" \
        && file_contains 'putawayMustNotDependOnGoodsreceiptposition' "$TEST" \
        && file_contains 'shouldLeaveCandidateListUnchangedWhenNoOverrideConfigured' "$TEST" \
        && file_contains 'caseLabelIsEmittedForEveryReceivedCase' "$RTEST"
}

REPO=src/main/java/net/aim_ai/wms/repo/jpa/LocationRepository.java
SVC=src/main/java/net/aim_ai/wms/service/mobile/MobilePutAwayService.java
RECV=src/main/java/net/aim_ai/wms/service/ReceivingService.java
TEST=src/test/java/net/aim_ai/wms/unit/service/mobile/MobilePutAwayServiceUnitTest.java
RTEST=src/test/java/net/aim_ai/wms/unit/service/ReceivingServiceUnitTest.java

echo
echo "SBDEV-2821 — route a tier-1 pick-face destination at PUTAWAY (option iii)"
echo "PROJECT_ROOT=$PROJECT_ROOT"
echo
echo "A. Repository seam (§3.2) — FIX rows except A4"

run A1 "LocationRepository declares getPutAwayCandidateLocations" \
    file_contains 'List<Location> +getPutAwayCandidateLocations' "$REPO"

run A2 "destination is a PARAMETER, not read from itemdata inside the query (SBDEV-2732 seam)" \
    file_contains_ml 'getPutAwayCandidateLocations\(.*?@Param\("configuredLocationId"\)\s+Long\s+configuredLocationId' "$REPO"

run A3 "new query is NOT HAL-exported (does not widen the REST surface)" \
    file_contains_ml '@RestResource\(exported = false\)\s*\n\s*@Query\([^;]*getPutAwayCandidateLocations' "$REPO"

run A4 "GUARD: getStorageLocationsForPutAwayItemData's WHERE is UNCHANGED (plan forbids relaxing it)" \
    file_contains_ml 'getStorageLocationsForPutAwayItemData[^;]*;' "$REPO"

run A5 "second UNION leg mirrors verifyScannedLocation's gate (useforstorage OR staginglane)" \
    file_contains_ml "l\.id = CAST\(:configuredLocationId AS bigint\)[^;]*a\.useforstorage = 'true' OR l\.staginglane = true" "$REPO"

# Added after code review (MEDIUM-1). Mirrors verifyScannedLocation's SECOND gate — the flowbin
# fixed-assignment check at :437-454 — so a flowbin bound to a DIFFERENT SKU is never offered. Nil
# exposure at tier 1; real under SBDEV-2732, where 1,344 of 2,068 flowbins on wms2-wineco-dev carry
# an assignment and a warehouse-scope default would surface a conflicted TOP suggestion (flowbins
# sort above overstock) for every SKU in scope.
run A6 "second leg excludes a flowbin fix-assigned to a DIFFERENT SKU (mirrors verifyScannedLocation gate 2)" \
    file_contains_ml 'NOT EXISTS \(SELECT 1 FROM fix_location_assignment fla.*fla\.itemdata_id <> :itemDataId' "$REPO"

echo
echo "B. calculatePutAwayList surfaces the destination (§3.2 + second-switch gap) — FIX rows"

run B1 "calculatePutAwayList passes the SKU's configured destination" \
    method_contains "$SVC" calculatePutAwayList 'getPutAwayCandidateLocations\(currentSku\.getId\(\), *currentSku\.getPutawaylocationId\(\)\)'

run B2 "calculatePutAwayList no longer uses the stock-only query" \
    method_not_contains "$SVC" calculatePutAwayList 'getStorageLocationsForPutAwayItemData'

run B3 "calculatePutAwayList's switch handles 'cases and pallets' (was silently dropped by default:)" \
    method_contains "$SVC" calculatePutAwayList 'case WmsConstants\.STORAGE_LOCATION_TYPE_STOCK_RESTRICTION'

echo
echo "C. storeBoxOnLocation consumes a club lane (§3.2a) — FIX rows"

run C1 "storeBoxOnLocation's switch handles 'cases and pallets'" \
    method_contains "$SVC" storeBoxOnLocation 'case WmsConstants\.STORAGE_LOCATION_TYPE_STOCK_RESTRICTION'

run C2 "'cases and pallets' waterfalls into the whole-unit-load branch" \
    file_contains_ml 'case WmsConstants\.STORAGE_LOCATION_TYPE_STOCK_RESTRICTION:\s*\n\s*unitloadBusinessService\.transferUnitLoadToLocation' "$SVC"

# A club lane is a LIVE MULTI-SKU pick face. If it acquired a FixLocationAssignment
# it would bind to whichever SKU was put away first and break every other SKU
# (fix_location_assignment is UNIQUE(assignedlocation_id)). The ONLY
# createFixedLocationAssignment in this method must be the flowbin one.
run C3 "GUARD: exactly one createFixedLocationAssignment in storeBoxOnLocation (flowbin branch only)" \
    bash -c "[ -f '$SVC' ] && [ \"\$(awk '/(public|private|protected|static).*[ ]storeBoxOnLocation\(/,/^    \}\$/' '$SVC' | grep -cE 'createFixedLocationAssignment\(')\" -eq 1 ]"

# Added after code review (MEDIUM-2). Adding 'cases and pallets' to the switch removed the incidental
# `default: throw` backstop for every such location outside a staging lane — including PutAwayLane
# (useforstorage=false) and 6 Outbound lanes. storeBoxOnLocation had NO area check of its own; the
# check lived only in the separate /verifyScannedLocation endpoint the client is trusted to call first.
run C4 "storeBoxOnLocation enforces the useforstorage/staginglane gate ITSELF, before the switch" \
    file_contains_ml 'storeBoxOnLocation[\s\S]*?locationAreaRepository\.findById\(location\.getAreaId\(\)\)[\s\S]*?!locationArea\.getUseforstorage\(\) && !location\.getStaginglane\(\)[\s\S]*?locationNotUsableForStorage' "$SVC"

run C5 "a test pins that gate against PutAwayLane specifically" \
    file_contains 'storeBoxOnLocationRefusesANonStorageLocation' "$TEST"

# Added after the SECOND review pass. Every other fixture in the file has useforstorage = true, which
# short-circuits the gate's `&&` so `getStaginglane()` is never actually read. Without this test a
# one-token simplification to `if (!locationArea.getUseforstorage())` breaks box putaway onto all 20
# StagingLaneNN on wms2-wineco-dev (all useforstorage=false / staginglane=true) with a green suite.
run C6 "a test pins the gate's staginglane RESCUE (useforstorage=false + staginglane=true accepted)" \
    file_contains 'storeBoxOnLocationAcceptsAStagingLaneWithNonStorageArea' "$TEST"

echo
echo "D. Scope discipline — GUARD rows (green both sides; prove no overreach)"

run D1 "GUARD: §8.1 'not needed' artifact resolveFlowbinResidentUnitload was NOT built" \
    tree_not_contains 'resolveFlowbinResidentUnitload'

run D2 "GUARD: none of the three §8.1 message keys were added" \
    tree_not_contains 'FlowbinAssignedToOtherSku|SkuAlreadyAssignedToFlowbin|FlowbinOccupiedWithoutAssignment'

run D3 "GUARD: ReceivingService still places tier-1 destinations unchanged (option iii never touches receiving)" \
    file_contains_ml 'if \(carrier == null\) \{\s*\n\s*unitloadBusinessService\.transferUnitLoadToLocation\(unitload, putAwayLocation' "$RECV"

run D4 "GUARD: no Flyway migration was added for this ticket (§5.1 row 5)" \
    bash -c '! ls src/main/resources/db/migration/ 2>/dev/null | grep -qi "2821"'

echo
echo "T. Tests — FIX rows"

run T1 "RED test: configured flowbin offered when the SKU has no stock anywhere" \
    file_contains 'shouldOfferConfiguredFlowbinWhenSkuHasNoStockAnywhere' "$TEST"

run T2 "RED test: configured 'cases and pallets' location offered" \
    file_contains 'shouldOfferConfiguredCasesAndPalletsLocation' "$TEST"

run T3 "RED test: club lane places without creating a FixLocationAssignment" \
    file_contains 'casesAndPalletsDestinationShouldPlaceWithoutCreatingFixLocationAssignment' "$TEST"

run T4 "guards present: M1a flowbin merge, C2b absence, no-override regression, case label" \
    all_guards_present

run_mvn T5 "the three RED tests EXIST and both contract classes pass" \
    red_tests_present_and_green

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
