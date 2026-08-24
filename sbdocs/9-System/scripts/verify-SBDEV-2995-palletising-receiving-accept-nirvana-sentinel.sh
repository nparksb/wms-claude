#!/usr/bin/env bash
# verify-SBDEV-2995-palletising-receiving-accept-nirvana-sentinel.sh
#
# Acceptance for: sbdocs/1-Projects/wms2/plan/SBDEV-2995-palletising-receiving-accept-nirvana-sentinel.md
# Usage: PROJECT_ROOT=/path/to/v2/wms2-api bash sbdocs/9-System/scripts/verify-SBDEV-2995-...sh
#
# REVISION 2 — after the architect review invalidated 3 of 4 sites and 5 near-miss shadows scored
# `22 pass, 0 fail` against revision 1.
#
# THE DEFECT REVISION 1 COULD NOT SEE: BRANCH STRUCTURE.
# Rows A1/A2 sliced the whole `palletise` method and asserted the guard appeared, and appeared before
# `transferUnitLoadToCarrier`. But BOTH arms of the `if (palletOpt.isEmpty())` are before that call —
# so a guard placed in the CREATE branch (leaving the bug 100% unfixed) was indistinguishable from one
# in the EXISTING branch. The single most important structural fact about this fix was invisible.
# Every A row below slices the `else` arm specifically.
#
# Carried forward from SBDEV-2994 (eleven self-caught defects) and revision 1 (three more):
#   - helpers fail CLOSED on a missing file; the template's fail OPEN
#   - greps read CODE, not comments (a token in a `// TODO` satisfied eight rows once)
#   - a bare negation over an absent construct is VACUOUSLY TRUE
#   - `\z` is NEVER a safe method-slice end anchor (it swallowed a later method and greened B1)
#   - patterns reach perl through the ENVIRONMENT (`@Foo` spliced into perl source is an ARRAY)
#   - no comment between env assignments and a continued command (the backslash eats it)
#   - every `run` target is defined (an undefined fn records bash 127 as an ordinary FAIL)
#   - alternations in an end-anchor need a non-capturing group
#
# ⚠ AND THE LESSON THAT COST THE MOST: a near-miss family written by the plan's author cannot test the
# plan's blind spots. Every mutation must be derived from reading the CODE, not the plan.
#
# ⚠⚠ READ THIS BEFORE TRUSTING A GREEN FROM THIS SCRIPT ⚠⚠
# An INDEPENDENT break lane found **13 false GREENS and 10 false REDS** against revision 2 — including
# unfixed code plus one dead decoy helper scoring every Fix row green (`slice` is a first-match-in-file
# search, so a decoy relocates the graded window), and a guard comparing against UNIT_LOAD_TYPE_CART
# while a PALLET lookup sat unused, which is strictly WORSE than shipping nothing.
#
# This is a structural ceiling of regex-over-source-text, not a patchable bug: a regex can express
# "these tokens appear near each other", never "this predicate, in this method, enforces this rule".
#
# THEREFORE: treat this script as a COARSE "did you touch the right files" check.
# A green here is NOT evidence the fix is correct. Semantic acceptance comes from:
#   1. executed unit tests, graded by MUTATION COVERAGE on the changed lines
#      → sbdocs/9-System/mutation-testing-recipe.md (PIT is verified working on this repo)
#   2. structural claims expressed as ArchUnit rules over BYTECODE, which decoys cannot fool
#      → see the five existing tests in src/test/java/net/aim_ai/wms/unit/config/
# See the plan's §7.7 and reviews/SBDEV-2995-break-report.md for the full finding.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0

PMV="src/main/java/net/aim_ai/wms/service/ParcelMonitorViewService.java"
MPS="src/main/java/net/aim_ai/wms/service/mobile/MobilePalletizingService.java"
MMU="src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java"
# CORRECTED at implementation time. Plan §5 proposed a NEW class; ParcelMonitorViewServiceUnitTest
# already exists on origin/develop with 28 tests and six @Nested classes, so the gate added a
# nested class beside them instead. T1-T3 pointed at a file that was never going to exist and
# were three false REDs from one stale premise.
T_PMV="src/test/java/net/aim_ai/wms/unit/service/ParcelMonitorViewServiceUnitTest.java"
T_MMU="src/test/java/net/aim_ai/wms/unit/service/mobile/MobileMoveUnitloadServiceUnitTest.java"

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then printf "  PASS  %-5s %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else printf "  FAIL  %-5s %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi
}
skip() { printf "  SKIP  %-5s %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

code_only() { [ -f "$1" ] || return 1; perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$1"; }
code_contains() { [ -f "$2" ] || return 1; code_only "$2" | grep -qE "$1"; }
file_exists() { [ -f "$1" ]; }

# Slice between two anchors. Patterns go through the ENV; no comment between assignments and perl.
slice() {
    local start=$1 end=$2 file=$3
    [ -f "$file" ] || return 1
    code_only "$file" | VW_S="$start" VW_E="$end" perl -0777 -ne 'print $1 if /$ENV{VW_S}(.*?)$ENV{VW_E}/ms'
}

# THE key helper: the EXISTING-label arm of palletise only — from the locked re-fetch to the
# carrier-already-loaded guard that closes it. A guard in the create arm is outside this window.
palletise_else_arm() {
    slice 'findByIdForUpdate\(palletOpt' 'assertPalletNotAssignedToGate\(' "$PMV"
}
# The CREATE arm, used to prove the regex stayed put and the guard did NOT land here.
palletise_create_arm() {
    slice 'if \(palletOpt\.isEmpty\(\)\)' 'findByIdForUpdate\(palletOpt' "$PMV"
}

order_within() {   # <body> <first-regex> <second-regex>
    local body=$1 a b
    [ -n "$body" ] || return 1
    a=$(printf '%s' "$body" | grep -nE "$2" | head -1 | cut -d: -f1)
    b=$(printf '%s' "$body" | grep -nE "$3" | head -1 | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

mvn_available() { command -v mvn >/dev/null 2>&1; }
mvn_test_passes() {
    mvn test -Dtest="$1" -DfailIfNoTests=false 2>&1 \
      | grep -qE "Tests run: [1-9][0-9]*,.*Failures: 0,.*Errors: 0"
}

# === A — Fix A: the type check, in the EXISTING-label arm ====================
check_A1_type_check_in_else_arm() {
    palletise_else_arm | perl -0777 -ne 'exit 1 unless /!\s*[A-Za-z_]+\.getTypeId\(\)\s*\.equals\((?:(?!;).)*?throw\s+new\s+BusinessException\(\s*"Not a pallet/s'
}
# Kills the "guard placed after the write" mutation. Anchored inside the else arm, so it also kills
# "guard in the create arm" — the arm slice returns nothing containing the check.
check_A2_type_check_before_carrier_write() {
    local body; body=$(slice 'findByIdForUpdate\(palletOpt' 'transferUnitLoadToCarrier\(' "$PMV") || return 1
    order_within "$body" 'getTypeId\(\)[^\n]*equals' 'setState|transferUnitLoadToCarrier'
}
check_A3_throws_the_sibling_message() {
    palletise_else_arm | grep -qE 'throw new BusinessException\("Not a pallet'
}
check_A4_pallet_type_resolved() {
    palletise_else_arm | grep -qE 'findByName\(WmsConstants\.UNIT_LOAD_TYPE_PALLET\)'
}

# NEW: pins §6.1's "deliberately no feature flag". A sysprop read between the locked re-fetch and
# the gate assertion means the guard can be switched off — inert on every tenant, full green.
check_A5_guard_is_not_sysprop_gated() {
    local arm; arm=$(palletise_else_arm) || return 1
    [ -n "$arm" ] || return 1
    ! printf '%s' "$arm" | grep -qE 'getSysvalue|parseBoolean'
}

# === B — Fix B: mobile move-unitload source guard ============================
check_B1_source_assert_extracted() {
    code_contains 'private void assertNotNirvanaSentinel\(' "$MMU"
}
# An EMPTY extracted method made Fix B inert and scored green on revision 1. Require a real predicate.
check_B2_source_assert_has_a_body() {
    slice 'private void assertNotNirvanaSentinel\(' '\n\s*(?:public|private|protected)\s' "$MMU" \
      | grep -qE 'getNirvana\(|STORAGE_LOCATION_NIRVANA'
}
check_B3_called_from_both_entry_points() {
    slice 'public TransferInfoDto scanUnitLoad\(' '\n\s*(?:public|private|protected)\s' "$MMU" \
      | grep -qE 'assertNotNirvanaSentinel\(' || return 1
    slice 'scanDestination' '\n\s*(?:public|private|protected)\s' "$MMU" \
      | grep -qE 'assertNotNirvanaSentinel\('
}
# The ordering that matters: before the 210,167-row materialisation at :264.
check_B4_called_before_stock_load() {
    local body; body=$(slice 'scanDestination' '\n\s*(?:public|private|protected)\s' "$MMU") || return 1
    printf '%s' "$body" | grep -qE '^[[:space:]]*assertNotNirvanaSentinel\(' || return 1
    # NOTE: no blanket getSysvalue ban here — scanDestination reads sysprops legitimately, and a
    # method-wide ban false-RED a correct implementation. The line-start anchor above already
    # rejects `if (Boolean.parseBoolean(...)) assertNotNirvanaSentinel(...)`, which is the
    # gated-and-inert shape this needs to catch.
    order_within "$body" 'assertNotNirvanaSentinel\(' 'findByUnitloadId\('
}

# === P — parity pins: already correct, must STAY correct =====================
# Revision 1's P1 grepped the constant file-wide and could not detect a hoist. Assert the throw is
# INSIDE the create arm.
check_P1_regex_stays_in_create_arm() {
    palletise_create_arm | grep -qE 'Not valid format'
}
check_P2_carrier_guard_retained() { code_contains 'getCarrierunitloadId\(\) != null' "$PMV"; }
check_P3_gate_assertion_retained() { code_contains 'assertPalletNotAssignedToGate\(' "$PMV"; }
# Mobile palletising is ALREADY correct (:257, :350) — the first draft wrongly proposed changing it.
# These pin that it is not "fixed" into a different shape.
check_P4_mobile_type_checks_untouched() {
    [ "$(code_only "$MPS" | grep -cE 'getTypeId\(\)[^\n]*equals')" -ge 2 ]
}
check_P5_mobile_not_given_the_collaborator() {
    code_only "$MPS" >/dev/null 2>&1 || return 1
    ! code_only "$MPS" | grep -qE 'assertCanReceiveStock\('
}

# === T — tests ===============================================================
check_T1_pmv_test_exists() { code_contains 'class Sbdev2995PalletTypeGuard' "$T_PMV"; }
# REPLACED: the plan's own §7.1 critic note forbids InOrder on unitloadTypeRepository.findByName --
# the CREATE arm calls it too (:141), so ordering on it cannot tell the arms apart. What actually
# needs pinning is that the refusal is exercised over the wrong-type fixtures.
check_T2_ordering_pinned() { code_contains 'ValueSource\(longs' "$T_PMV"; }
check_T3_no_write_pinned() { code_contains 'never\(\)' "$T_PMV"; }
# BASELINE DEFECT CAUGHT: a bare `findByUnitloadId` grep passed on the unfixed tree — the existing
# test class already mentions the symbol, so the row could not distinguish "covers the new ordering"
# from "mentions it at all". Require the NEGATIVE assertion that pins it: the stock load must not run.
check_T4_mmu_test_covers_ordering() {
    code_contains 'never\(\)\)[[:space:]]*\.findByUnitloadId|never\(\)\)\.findByUnitloadId' "$T_MMU"
}

echo
echo "verify-SBDEV-2995 (rev 2) — outbound palletising pallet-type check"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo
echo "-- Fix A: type check in the EXISTING-label arm --"
run A1 "A1  type check inside the else arm"           check_A1_type_check_in_else_arm
run A2 "A2  it runs before the carrier write"         check_A2_type_check_before_carrier_write
run A3 "A3  THROWS (not logs) 'Not a pallet'"         check_A3_throws_the_sibling_message
run A4 "A4  compares against UNIT_LOAD_TYPE_PALLET"   check_A4_pallet_type_resolved
run A5 "A5  guard is NOT sysprop-gated"               check_A5_guard_is_not_sysprop_gated
echo
echo "-- Fix B: mobile move-unitload source guard --"
run B1 "B1  assertNotNirvanaSentinel extracted"    check_B1_source_assert_extracted
run B2 "B2  it has a real body (not an empty stub)"   check_B2_source_assert_has_a_body
run B3 "B3  called from both entry points"            check_B3_called_from_both_entry_points
run B4 "B4  called BEFORE findByUnitloadId (210k)"    check_B4_called_before_stock_load
echo
echo "-- Parity pins (green before AND after) --"
run P1 "P1  format regex stays in the CREATE arm"     check_P1_regex_stays_in_create_arm
run P2 "P2  carrier-already-loaded guard retained"    check_P2_carrier_guard_retained
run P3 "P3  assertPalletNotAssignedToGate retained"   check_P3_gate_assertion_retained
run P4 "P4  mobile type checks untouched (x2)"        check_P4_mobile_type_checks_untouched
run P5 "P5  mobile NOT given the 2994 collaborator"   check_P5_mobile_not_given_the_collaborator
echo
echo "-- Tests --"
run T1 "T1  Sbdev2995PalletTypeGuard nested class"   check_T1_pmv_test_exists
run T2 "T2  refusal parameterised over wrong types"  check_T2_ordering_pinned
run T3 "T3  'no write' pinned with never()"           check_T3_no_write_pinned
run T4 "T4  MMU test covers the 210k ordering"        check_T4_mmu_test_covers_ordering
echo

# Default 1, not 0: SBDEV-2217 means there is no runnable IT lane, so these unit tests are the
# ENTIRE runtime evidence base. Rev 1's headline "0 fail" was grep-only and executed nothing.
if [ "${RUN_MVN:-1}" = "1" ]; then
    if mvn_available; then
        echo "-- Targeted maven runs --"
        run M1 "M1  ParcelMonitorViewServicePalletTypeGuardTest" mvn_test_passes ParcelMonitorViewServicePalletTypeGuardTest
        run M2 "M2  MobileMoveUnitloadServiceUnitTest"           mvn_test_passes MobileMoveUnitloadServiceUnitTest
        echo
    else
        # HARD FAIL, not SKIP. An independent break lane demonstrated that `mvn` is SDKMAN-only on
        # this box, so the default path printed SKIP and exited 0 with ZERO code executed — while the
        # header claimed RUN_MVN=1 was required for acceptance. Documentation is not enforcement.
        printf "  FAIL  %-5s %s\n" "MVN" "RUN_MVN=1 requested but mvn is not on PATH — export SDKMAN's maven"
        FAIL=$((FAIL+1))
    fi
else
    # ⚠ The grep rows are code-SHAPE only. Revision 1's headline "22 pass / 0 fail" was a grep-only
    # result because this defaulted to 0 and nothing ever executed. Final acceptance requires RUN_MVN=1.
    skip M1-M2 "M1-M2 targeted maven runs" "set RUN_MVN=1 — required for final acceptance"
fi

echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
