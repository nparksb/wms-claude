#!/usr/bin/env bash
# verify-SBDEV-2731-alternate-putaway-location-not-honored-receiving.sh
#
# Machine-checkable acceptance for:
#   SBDEV-2731 — Alternate putaway location is displayed wrong and rejected on receive
#   Plan: sbdocs/1-Projects/wms2/plan/SBDEV-2731-alternate-putaway-location-not-honored-receiving.md
#
# Usage
# -----
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2731-alternate-putaway-location-not-honored-receiving.sh
#   $ PROJECT_ROOT=/path/to/monorepo RUN_TESTS=1 bash .../verify-SBDEV-2731-....sh
#
# This plan spans TWO repositories, so PROJECT_ROOT is the monorepo root that
# contains both v2/wms2-api and v2/wms2-web-ui — NOT a single project root as in
# most sibling scripts.
#
# SCOPE, as of 2026-08-02 (D14). This ticket ships PR1 ONLY — Fix A (bind the
# receiving screen to the real destination) and Fix C (neutral, bundle-keyed
# constraint message at UnitloadBusinessService:191).
#
# Fix B — ReceivingService flowbin routing — was RELOCATED to SBDEV-2732 and is
# still gated on Q5/C2b. Its checks (B1-B15) and the three Flowbin*/SkuAlready*
# message keys (M3-M8) are therefore SKIPPED here, not deleted: the assertions
# are the relocated specification and must stay visible in the output.
#
# The capacity question behind Q5 (F3) is owned by SBDEV-2796.
#
# Acceptance for PR1 is "Result: 27 pass, 0 fail, 22 skip" with RUN_TESTS=1, and
# the implementer MUST paste that literal line into the PR. Do NOT green this
# script by deleting the skipped checks.
#
# BASELINE LABEL. 27, NOT 26 — corrected 2026-08-06. The code review added check A10 (the tri-state
# `=== false` pin) on 2026-08-06 and the plan was updated to 27; this header was not, so the script
# and the plan disagreed by one. An implementer pasting "26 pass" from here would have reported a
# number the plan calls a failure.
# Measured against origin/develop api 169065c / ui 743142e, PRE-merge of PR #133 / #39.
# Expires on that merge — re-measure and re-record rather than trusting this line.
#
# BASELINE FIRST. Run this before touching any code and record the FAIL count in
# the plan's §7.2 step 1. A grep script cannot prove its own assertions have
# teeth; only the pre-fix baseline can.
#
# ---------------------------------------------------------------------------
# TEMPLATE HAZARD, proven 2026-07-31 — read before editing the helpers.
#
# verify-plan-template.sh's `file_not_contains` FAILS OPEN: on a missing file
# `grep -qE` exits 2, and the leading `!` turns that non-zero into a PASS. Every
# negative assertion would therefore green against a path that does not exist —
# which matters acutely here, because Fix A targets a file in a DIFFERENT repo
# and one mistyped path would silently "prove" the fix.
#
# This script overrides it with an explicit -f guard, and pairs every negative
# with an X* existence check on the same file. Do NOT simplify it back.
#
# `file_contains` (positive) is safe as written: grep's exit 2 stays non-zero and
# correctly FAILS. The template defines no perl helper — do not add one.
# ---------------------------------------------------------------------------

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

API="v2/wms2-api"
UI="v2/wms2-web-ui"

RECEIVING_SVC="$API/src/main/java/net/aim_ai/wms/service/ReceivingService.java"
UL_BIZ_SVC="$API/src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java"
MSG_EN="$API/src/main/resources/messages_en_US.properties"
MSG_BASE="$API/src/main/resources/messages.properties"
RECEIVING_FORM="$UI/components/receiving/open/receive/receivingForm.vue"
# Mirrors the component path, matching the suite's convention
# (test/components/processes/clubRuns/clubRunDetails.spec.js ← components/.../clubRunDetails.vue).
RECEIVING_SPEC="$UI/test/components/receiving/open/receive/receivingForm.spec.js"

RUN_TESTS="${RUN_TESTS:-0}"

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
    local id=$1 desc=$2 reason=$3
    printf "  SKIP  %-10s  %s  (%s)\n" "$id" "$desc" "$reason"; SKIP=$((SKIP+1))
}

# ============================================================================
# SCOPE CHANGE 2026-08-02 (D14) — the 15 B* checks are SKIPPED, not deleted
# ============================================================================
# Fix B (flowbin routing / ReceivingService destination resolution) moved to
# SBDEV-2732. This ticket closes on PR1. The B* assertions are retained because
# they are the specification that transfers with the work — but they must not
# FAIL this ticket's gate, and they must not read as green either. They are
# skips. When SBDEV-2731 Q5 is answered, port them into
# verify-SBDEV-2732-configurable-default-putaway-location-hierarchy.sh.
#
# A PR1-only run should therefore show: the A*/C* checks live, 15 B* skips.
# --- assertion helpers -------------------------------------------------------

file_exists() { [ -f "$1" ]; }

file_contains() { grep -qE "$1" "$2"; }

# OVERRIDE of the template's fail-open version. See TEMPLATE HAZARD above.
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }

file_contains_n_times() {
    local pattern=$1 file=$2 n=$3 count
    [ -f "$file" ] || return 1
    count=$(grep -cE "$pattern" "$file" 2>/dev/null || echo 0)
    [ "$count" -ge "$n" ]
}

# FIXED 2026-08-02 (during implementation): the previous body could NEVER return
# true, making the plan's own stated acceptance (`Result: 26 pass, 0 fail`)
# unreachable. It ran maven with `-q`, which suppresses INFO — so neither
# "BUILD SUCCESS" nor the "Tests run: ..." summary is ever printed on a passing
# run, and the grep matched nothing. Proven by running the exact body against a
# class that passes 37/37: 3051 bytes of app logging, no match, reported FAIL.
#
# Now gates on maven's EXIT CODE (the actual authority) AND on a summary showing a
# NON-ZERO test count with zero failures. The count guard closes the @Nested trap
# the plan warns about in §8.5 — `-Dtest='Outer#method'` silently matches nothing
# and would otherwise read as a pass.
mvn_test_passes() {
    local test_class=$1 out
    out=$( cd "$API" && mvn test -Dtest="$test_class" -DfailIfNoTests=false 2>&1 ) || return 1
    printf '%s\n' "$out" | grep -qE "Tests run: [1-9][0-9]*, Failures: 0, Errors: 0"
}

# Fix A lives in wms2-web-ui and had NO behavioural gate at all — RUN_TESTS=1 ran
# only maven. There is no `yarn` on PATH here, so invoke the local jest binary
# directly (same recipe as the recorded wms2-mobile-ui / wms-web-ui runs).
# Fails (rather than skips) if jest is not installed, so a missing node_modules
# cannot be mistaken for a passing UI gate.
# FIXED 2026-08-02 (verifier finding G1): the previous body piped jest into
# `grep -qE "Tests:.*[0-9]+ passed"`, so the pipeline's status was GREP's and jest's
# non-zero exit was discarded. Proven with a real run, not reasoned: a spec with
# 1 failing + 1 passing test printed "Tests: 1 failed, 6 passed, 7 total" and the
# helper still returned 0. T3 is Fix A's only behavioural gate, so that was the same
# fail-open species §9 closed for file_not_contains.
#
# Now gates on jest's EXIT CODE, with the count grep kept purely as a zero-test guard
# (jest exits 0 when a pattern matches no suites at all).
jest_test_passes() {
    local pattern=$1 out
    [ -x "$UI/node_modules/.bin/jest" ] || return 1
    out=$( cd "$UI" && node_modules/.bin/jest --testPathPattern="$pattern" \
        --coverage=false --silent 2>&1 ) || return 1
    printf '%s\n' "$out" | grep -qE "Tests:.*[1-9][0-9]* passed"
}

# === X* — target files exist (guards every negative assertion below) =========

check_X1() { file_exists "$RECEIVING_SVC"; }
check_X2() { file_exists "$UL_BIZ_SVC"; }
check_X3() { file_exists "$MSG_EN"; }
check_X4() { file_exists "$MSG_BASE"; }
check_X5() { file_exists "$RECEIVING_FORM"; }

# === Fix A (PR1) — receiving screen shows the real destination ================

# POSITIVE: the template INTERPOLATES the value rather than rendering a constant.
# Must not assert bare 'putawayStaging' — that string already exists pre-fix as a
# dead data prop (line 206), so it would false-pass on unmodified code.
#
# RETARGETED 2026-08-02: was '\{\{ *putawayStaging'. The plan gave two mutually
# exclusive templates — an early draft interpolating `putawayStaging ||
# DEFAULT_PUTAWAY_LANE_NAME`, and §5's closing statement that the template binds
# `putawayDisplay`. Only the latter is valid: DEFAULT_PUTAWAY_LANE_NAME is a
# module-scope const, and Vue 2 compiles templates with `with(this)`, so a bare
# module identifier inside {{ }} resolves against the component instance, warns
# "not defined on the instance" and renders empty. The computed is the correct
# seam; this check now pins it.
check_A1() { file_contains '\{\{ *putawayDisplay' "$RECEIVING_FORM"; }

# POSITIVE: the value is sourced from the view field already on the payload.
check_A2() { file_contains 'defaultputawaylocationname' "$RECEIVING_FORM"; }

# POSITIVE: overrides are distinguishable from the standard lane.
check_A3() { file_contains 'isPutawayOverride' "$RECEIVING_FORM"; }

# NEGATIVE: the hard-coded literal is gone (the actual Bug A defect).
check_A4() { file_not_contains '<label class="ml-4">Put Away Lane</label>' "$RECEIVING_FORM"; }

# NEGATIVE: the spaced literal must never appear in a COMPARISON. The lane's real
# location.name is 'PutAwayLane' (WmsConstants.java:771); comparing against the
# spaced display label makes isPutawayOverride true for every SKU. The spaced form
# is legal only as a display constant, which is why this targets ===/!== and
# ternaries rather than the bare string.
check_A5() { file_not_contains "[=!]==? *'Put Away Lane'" "$RECEIVING_FORM"; }

# POSITIVE: the comparison uses the real location name.
check_A6() { file_contains "'PutAwayLane'" "$RECEIVING_FORM"; }

# POSITIVE: operators see the friendly label, not the machine name. Asserts the
# computed is DEFINED (A1 asserts it is rendered) — a bare 'putawayDisplay' grep
# would be satisfied by A1's interpolation alone.
check_A7() { file_contains 'putawayDisplay *\(' "$RECEIVING_FORM"; }

# POSITIVE: the previously-dead prop is actually populated from the payload.
# Without this, putawayStaging can stay null forever and putawayDisplay silently
# renders the fallback label for every SKU — indistinguishable from the old bug.
check_A8() { file_contains 'putawayStaging *= *newVal\.defaultputawaylocationname' "$RECEIVING_FORM"; }

# POSITIVE: the Jest spec for Fix A exists. Fix A is half of PR1 and was otherwise
# guarded only by greps — including T20a, the regression guard for the always-true
# isPutawayOverride bug the plan devotes a warning box to.
check_A9() { file_exists "$RECEIVING_SPEC"; }

# POSITIVE: the M1 amendment's guard survives, and survives TRI-STATE.
#
# A1/A3/A7 pin putawayDisplay and isPutawayOverride but nothing pinned
# isPutawayDestinationApplied — delete it and its span and every other check here
# still passed, with only Jest T21 objecting. The plan's §5 warning box calls this
# guard the correction to a WRONG SHIPPED REVISION (the screen asserting a
# destination the receipt ignores), so it earns a static gate of its own.
#
# The `=== false` half is not cosmetic: the computed returns null for "the operator
# has not chosen yet", and a falsy `!` test would re-assert "not used" on the
# untouched default render (review finding #1). Pinning the strict comparison stops
# a later simplification to `!isPutawayDestinationApplied` from silently restoring it.
check_A10() {
    file_contains 'isPutawayDestinationApplied' "$RECEIVING_FORM" &&
    file_contains 'isPutawayDestinationApplied === false' "$RECEIVING_FORM"
}

# === Fix C (PR1) — actionable, bundle-keyed constraint message ================

# POSITIVE: the throw uses a bundle key.
#
# RENAMED 2026-08-02 to `unitloadTypeNotPermittedOnLocation`. SBDEV-2732 declares
# this exact key at :191 as a HARD PREREQUISITE it will consume (2732 §5.1 row 0,
# §7.2 step 6: "Do not re-specify :191 — that is 2731 PR1's line"). Shipping a
# differently-named key would break 2732 at implementation time on a key that was
# never created. The unprefixed form also matches the bundle's existing convention
# (cf. STORAGELOCATION_LOCKED at messages_en_US.properties:287).
check_C1() { file_contains 'unitloadTypeNotPermittedOnLocation' "$UL_BIZ_SVC"; }

# NEGATIVE: :191 serves 35 callers — picking, palletizing, truck loading, transfers,
# nirvana — none of which have a configured putaway destination. A putaway-specific
# remedy clause here is actively misleading for 34 of them, so the remedy text lives
# on SBDEV-2732's separate resolver-thrown key, never at this site.
check_C6() { file_not_contains 'putawayDestinationNotPermitted' "$UL_BIZ_SVC"; }

# NEGATIVE: the raw ID-laden concatenation is gone (the actual Bug C defect).
check_C2() { file_not_contains '"unitloadtypeId=" \+' "$UL_BIZ_SVC"; }

# POSITIVE: rejection is logged with business context.
check_C3() { file_contains 'LOG\.warn\(.*location constraint' "$UL_BIZ_SVC"; }

# POSITIVE (regression): the gate LOGIC is untouched — Fix C is message-only.
check_C4() { file_contains 'locationConstraintRepository\.findByStoragelocationtypeId' "$UL_BIZ_SVC"; }

# POSITIVE: names, not ids, are resolved for the message.
check_C5() { file_contains 'unitloadTypeRepository\.findNameById' "$UL_BIZ_SVC"; }

# === M* — message keys present in BOTH bundles ===============================
# Asserted per-file on purpose: a glob over messages*.properties would pass with
# the key in only one file, and the base bundle is what makes it resolve under a
# non-en_US default locale (precedent: SBDEV-2729).

check_M1() { file_contains '^unitloadTypeNotPermittedOnLocation=' "$MSG_EN"; }
check_M2() { file_contains '^unitloadTypeNotPermittedOnLocation=' "$MSG_BASE"; }

# M3-M8 are the three Flowbin*/SkuAlready* keys. They are thrown ONLY by Fix B,
# which relocated to SBDEV-2732 (D14), so PR1 must NOT ship them — unreachable
# operator-facing strings invite a reviewer to wire them up prematurely. Kept as
# definitions so the relocated spec stays readable; SKIPPED in the runner.
check_M3() { file_contains '^BusinessException\.FlowbinAssignedToOtherSku=' "$MSG_EN"; }
check_M4() { file_contains '^BusinessException\.FlowbinAssignedToOtherSku=' "$MSG_BASE"; }
check_M5() { file_contains '^BusinessException\.SkuAlreadyAssignedToFlowbin=' "$MSG_EN"; }
check_M6() { file_contains '^BusinessException\.SkuAlreadyAssignedToFlowbin=' "$MSG_BASE"; }
check_M7() { file_contains '^BusinessException\.FlowbinOccupiedWithoutAssignment=' "$MSG_EN"; }
check_M8() { file_contains '^BusinessException\.FlowbinOccupiedWithoutAssignment=' "$MSG_BASE"; }

# POSITIVE: positional args use the bundle's dominant %1$s convention, not %1s.
# (SBDEV-2729 revision 2 recorded a false-fail from asserting the wrong form.)
check_M9() { file_contains '^unitloadTypeNotPermittedOnLocation=.*%1\$s' "$MSG_EN"; }

# NEGATIVE: the neutral key must carry no putaway remedy clause — see C6.
check_M10() { file_not_contains '^unitloadTypeNotPermittedOnLocation=.*Default Putaway Location' "$MSG_EN"; }

# === Fix B (PR2) — classify the destination, use the right primitive ==========

# POSITIVE: the flowbin resident-UL resolver exists.
check_B1() { file_contains 'resolveFlowbinResidentUnitload' "$RECEIVING_SVC"; }

# POSITIVE: receiving now classifies by location type.
check_B2() { file_contains 'STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN' "$RECEIVING_SVC"; }

# POSITIVE: the stock-transfer primitive is used (the core of Fix B).
check_B3() { file_contains 'transferStockToUnitLoad' "$RECEIVING_SVC"; }

# POSITIVE (regression): the whole-UL primitive still exists for non-flowbin
# destinations — AC 2's guard. Fix B must ADD a branch, not replace the path.
check_B4() { file_contains 'transferUnitLoadToLocation' "$RECEIVING_SVC"; }

# POSITIVE: D1' auto-create reuses the existing service, not a hand-rolled insert.
check_B5() { file_contains 'createFixedLocationAssignment' "$RECEIVING_SVC"; }

# POSITIVE: all three D1' rejection keys are actually thrown.
check_B6() { file_contains 'BusinessException\.FlowbinAssignedToOtherSku' "$RECEIVING_SVC"; }
check_B7() { file_contains 'BusinessException\.SkuAlreadyAssignedToFlowbin' "$RECEIVING_SVC"; }
check_B8() { file_contains 'BusinessException\.FlowbinOccupiedWithoutAssignment' "$RECEIVING_SVC"; }

# NEGATIVE: the carrier-gated ternary that silently discarded the override (D2)
# is gone. Specific to the old shape — `carrier == null` legitimately survives
# elsewhere in the method, so asserting on that alone would be vacuous.
check_B9() { file_not_contains 'Location putAwayLocation = \(carrier == null\)' "$RECEIVING_SVC"; }

# POSITIVE: C1 — the case label is suppressed on the flowbin path.
check_B10() { file_contains 'if \(flowbinResidentUnitload == null\)' "$RECEIVING_SVC"; }

# POSITIVE: C2 — the goods-receipt position write is extracted so it can run
# after the move against the surviving stock unit.
check_B11() { file_contains 'saveGoodsreceiptPosition' "$RECEIVING_SVC"; }

# POSITIVE: the D1' rationale comment survives. It is load-bearing — it is the
# only thing stopping a reviewer from loosening the guard to match
# MobilePutAwayService/StockunitService or tightening it back to a hard reject.
check_B12() { file_contains_n_times 'SBDEV-2731' "$RECEIVING_SVC" 2; }

# POSITIVE: the auto-create (the one non-idempotent effect) is logged.
check_B13() { file_contains 'LOG\.info\(.*FixLocationAssignment' "$RECEIVING_SVC"; }

# POSITIVE: C1 follow-through — an all-flowbin receipt produces no labels, so the
# post-commit print must not ship a zero-length job to CUPS.
check_B14() { file_contains 'labelData\.length' "$RECEIVING_SVC"; }

# POSITIVE: the C2a rationale is carried in-code. transferStockToUnitLoad returns the
# DESTINATION stock unit holding the MERGED amount, so the goods-receipt row must record
# this case's quantity instead — otherwise the allowoverdelivery sum at :373-378 inflates.
# Deliberately a marker check: the real guard is behavioural (test T8a), because any
# grep for the correct arithmetic would be satisfiable by the wrong code too.
check_B15() { file_contains 'C2a' "$RECEIVING_SVC"; }

# === Wire into the runner ====================================================

echo
echo "verify-SBDEV-2731 — alternate putaway location not displayed or honored"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  RUN_TESTS=$RUN_TESTS  (set RUN_TESTS=1 to include the T* maven checks)"
echo

echo "-- X: target files exist (guards the negative assertions) --"
run X1  "ReceivingService.java present"          check_X1
run X2  "UnitloadBusinessService.java present"   check_X2
run X3  "messages_en_US.properties present"      check_X3
run X4  "messages.properties present"            check_X4
run X5  "receivingForm.vue present (web-ui)"     check_X5
echo

echo "-- A: Fix A — receiving screen displays the real destination (PR1) --"
run A1  "putawayStaging bound in template"       check_A1
run A2  "sources defaultputawaylocationname"     check_A2
run A3  "isPutawayOverride distinguishes override" check_A3
run A4  "NEG hard-coded 'Put Away Lane' label gone" check_A4
run A5  "NEG spaced literal not in a comparison [guard: passes pre-fix]" check_A5
run A6  "compares against real name 'PutAwayLane'"  check_A6
run A7  "operators see friendly label, not machine name" check_A7
run A8  "dead putawayStaging prop actually populated"  check_A8
run A9  "receivingForm.spec.js exists (Fix A coverage)" check_A9
run A10 "tri-state applied-destination guard kept" check_A10
echo

echo "-- C: Fix C — actionable constraint message (PR1) --"
run C1  "throws bundle key, not a raw string"    check_C1
run C2  "NEG raw 'unitloadtypeId=' concat gone"  check_C2
run C3  "rejection logged with context"          check_C3
run C4  "REGRESSION gate logic still present"    check_C4
run C5  "resolves UL type NAME for the message"  check_C5
run C6  "NEG putaway remedy absent from shared site [guard: passes pre-fix]" check_C6
echo

echo "-- M: message keys in BOTH bundles (locale-independent resolution) --"
run  M1  "unitloadTypeNotPermittedOnLocation en_US" check_M1
run  M2  "unitloadTypeNotPermittedOnLocation base"  check_M2
skip M3  "FlowbinAssignedToOtherSku in en_US"     "relocated to SBDEV-2732 (D14); thrown only by Fix B"
skip M4  "FlowbinAssignedToOtherSku in base"      "relocated to SBDEV-2732 (D14); thrown only by Fix B"
skip M5  "SkuAlreadyAssignedToFlowbin in en_US"   "relocated to SBDEV-2732 (D14); thrown only by Fix B"
skip M6  "SkuAlreadyAssignedToFlowbin in base"    "relocated to SBDEV-2732 (D14); thrown only by Fix B"
skip M7  "FlowbinOccupiedWithoutAssignment en_US" "relocated to SBDEV-2732 (D14); thrown only by Fix B"
skip M8  "FlowbinOccupiedWithoutAssignment base"  "relocated to SBDEV-2732 (D14); thrown only by Fix B"
run  M9  "uses %1\$s positional convention"       check_M9
run  M10 "NEG neutral key has no putaway remedy [guard: passes pre-fix]" check_M10
echo

echo "-- B: Fix B — flowbin routing (PR2) --"
skip B1   "resolveFlowbinResidentUnitload exists" "relocated to SBDEV-2732 (D14); still gated on Q5/C2b"
skip B2   "classifies destination by FLOWBIN type" "relocated to SBDEV-2732 (D14); still gated on Q5/C2b"
skip B3   "uses transferStockToUnitLoad primitive" "relocated to SBDEV-2732 (D14); still gated on Q5/C2b"
skip B4   "REGRESSION whole-UL path retained" "relocated to SBDEV-2732 (D14); still gated on Q5/C2b"
skip B5   "reuses createFixedLocationAssignment" "relocated to SBDEV-2732 (D14); still gated on Q5/C2b"
skip B6   "throws FlowbinAssignedToOtherSku" "relocated to SBDEV-2732 (D14); still gated on Q5/C2b"
skip B7   "throws SkuAlreadyAssignedToFlowbin" "relocated to SBDEV-2732 (D14); still gated on Q5/C2b"
skip B8   "throws FlowbinOccupiedWithoutAssignment" "relocated to SBDEV-2732 (D14); still gated on Q5/C2b"
skip B9   "NEG carrier-gated ternary (D2) gone" "relocated to SBDEV-2732 (D14); still gated on Q5/C2b"
skip B10  "C1 case label suppressed on flowbin" "relocated to SBDEV-2732 (D14); still gated on Q5/C2b"
skip B11  "C2 GRP write extracted for reordering" "relocated to SBDEV-2732 (D14); still gated on Q5/C2b"
skip B12  "D1' rationale comment retained" "relocated to SBDEV-2732 (D14); still gated on Q5/C2b"
skip B13  "auto-create logged at INFO" "relocated to SBDEV-2732 (D14); still gated on Q5/C2b"
skip B14  "C1 empty label stream not sent to CUPS" "relocated to SBDEV-2732 (D14); still gated on Q5/C2b"
skip B15  "C2a per-case amount rationale carried" "relocated to SBDEV-2732 (D14); still gated on Q5/C2b"
echo

echo "-- T: targeted unit tests (code shape is necessary, not sufficient) --"
# T1 was ReceivingServiceUnitTest. PR1 touches nothing in ReceivingService, so it
# was a no-op pass here; the class is Fix B's gate and went with it to SBDEV-2732.
skip T1 "ReceivingServiceUnitTest" "relocated to SBDEV-2732 (D14); PR1 does not touch ReceivingService"

if [ "$RUN_TESTS" = "1" ]; then
    run T2 "UnitloadBusinessServiceUnitTest passes" mvn_test_passes UnitloadBusinessServiceUnitTest
    run T3 "receivingForm.spec.js passes (Fix A)"   jest_test_passes receivingForm
else
    skip T2 "UnitloadBusinessServiceUnitTest" "RUN_TESTS=0; mvn also mutates the tracked archunit_store"
    skip T3 "receivingForm.spec.js"           "RUN_TESTS=0"
fi
echo
echo "  NOTE: do NOT invoke these with -Dtest='Outer#method' — Surefire silently"
echo "        matches nothing for @Nested tests and reports a false green."
echo "  NOTE: 'mvn test' mutates the tracked archunit_store file — revert it."
echo

echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

# --- acceptance gate ---------------------------------------------------------
# REWRITTEN 2026-08-02. The original rationale cited check_B11/check_B15 and the
# C2/C2a ordering defect — all of which are now SKIPPED (relocated to SBDEV-2732),
# so every word of it was void.
#
# The gate still earns its place, for a different reason. Both halves of PR1 are
# guarded mainly by greps, and greps cannot see behaviour:
#   * Fix C — check_C1/M1/M2 confirm the KEY EXISTS. They cannot tell whether it
#     RESOLVES. A key present in the bundles but misspelled at the throw site,
#     or missing its positional args, renders as the raw key or an empty string
#     to the operator. Only T2 catches that.
#   * Fix A — A1-A9 are all static. The always-true isPutawayOverride bug (the
#     plan's own warning box) is a RUNTIME defect: comparing against the spaced
#     'Put Away Lane' display literal instead of the real 'PutAwayLane' location
#     name. check_A5 is a negative grep that passes pre-fix by construction, so
#     T3/T20a is the only thing that actually proves the comparison is right.
if [ "$FAIL" -eq 0 ] && [ "$RUN_TESTS" != "1" ]; then
    echo
    echo "  NOT ACCEPTANCE — all code-shape checks pass, but the behavioural"
    echo "  guards (T2 = Fix C message resolution, T3 = Fix A override logic)"
    echo "  were skipped. Re-run with RUN_TESTS=1."
    echo "  A bundle key can exist and still not resolve; isPutawayOverride can"
    echo "  be always-true and still satisfy every grep here."
    exit 2
fi

[ "$FAIL" -eq 0 ]
