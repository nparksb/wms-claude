#!/usr/bin/env bash
# verify-260427-changeReservedAmount-caller-rebind-followup.sh
#
# Acceptance script for plan:
#   sbdocs/1-Projects/wms1/plan/260427-changeReservedAmount-caller-rebind-followup.md
#
# Encodes Fix A (MobileReplenishService:420/424), Fix B (ReleaseOrderJobService:473),
# Fix C/D (regression tests) as machine-checkable assertions.
#
#   $ bash sbdocs/9-System/scripts/verify-260427-changeReservedAmount-caller-rebind-followup.sh
#
# Exit 0 only when every active check passes.
# Set SKIP_MVN=1 to skip maven test runs (faster local iteration).

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/Users/np1076/dev/spk/owl/v1/wms-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-14s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-14s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    printf "  SKIP  %-14s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1))
}

file_contains()     { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { ! grep -qE "$1" "$2" 2>/dev/null; }
file_contains_n()   {
    local pat=$1 file=$2 n=$3
    local c; c=$(grep -cE "$pat" "$file" 2>/dev/null || echo 0)
    [ "$c" -ge "$n" ]
}
mvn_test_passes() {
    mvn test -Dtest="$1" -DfailIfNoTests=false >/dev/null 2>&1
}

MR=src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java
ROJ=src/main/java/net/aim_ai/wms/service/job/ReleaseOrderJobService.java
SBS=src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java

MR_TEST=src/test/java/net/aim_ai/wms/unit/service/mobile/MobileReplenishServiceUnitTest.java
ROJ_TEST=src/test/java/net/aim_ai/wms/unit/service/job/ReleaseOrderJobServiceUnitTest.java
SBS_TEST=src/test/java/net/aim_ai/wms/unit/service/StockunitBusinessServiceUnitTest.java
PBS_TEST=src/test/java/net/aim_ai/wms/unit/service/PickingorderBusinessServiceUnitTest.java

echo
echo "verify-260427-changeReservedAmount-caller-rebind-followup"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# ===========================================================================
# Fix A — MobileReplenishService.finishReplenishmentOrderInternal rebinds sourceStock
# ===========================================================================
echo "── Fix A: MobileReplenishService rebinds sourceStock at L420 and L424 ──"
echo

# POSITIVE: exactly 2 occurrences of `sourceStock = stockunitBusinessService.changeReservedAmount(sourceStock, ...)` (one per branch)
run FA-1-pos "rebind 'sourceStock = stockunitBusinessService.changeReservedAmount(sourceStock' appears exactly 2 times" \
    bash -c "[ \$(grep -cE 'sourceStock\s*=\s*stockunitBusinessService\.changeReservedAmount\(\s*sourceStock' $MR 2>/dev/null) -eq 2 ]"

# NEGATIVE (strengthened per critic M2): explicit count == 0 for bare statement form `^\s+stockunitBusinessService.changeReservedAmount(sourceStock`
# This makes the assertion symmetric with FA-1-pos and decouples it from the >=2 count.
run FA-1-neg "bare statement 'stockunitBusinessService.changeReservedAmount(sourceStock' count == 0 (no un-rebound caller remains)" \
    bash -c "[ \$(grep -cE '^\s+stockunitBusinessService\.changeReservedAmount\(\s*sourceStock' $MR 2>/dev/null) -eq 0 ]"

# POSITIVE: the OLD-stockUnit release inside the split branch (L426) intentionally stays bare — verify it is still present
run FA-2-pos "L426 release of redirected 'stockUnit' (not 'sourceStock') stays bare-call (intentionally not rebound)" \
    file_contains 'stockunitBusinessService\.changeReservedAmount\(\s*stockUnit\s*,\s*stockUnit\.getReservedamount\(\)\.negate\(\)' "$MR"

echo

# ===========================================================================
# Fix B — ReleaseOrderJobService.createPickingForOrder rebinds stockUnit at L473
# ===========================================================================
echo "── Fix B: ReleaseOrderJobService rebinds stockUnit at L473 ─────────────"
echo

# POSITIVE: exactly 1 rebind in this file (the L473 fixedAssignments site)
# (uniquely identified by `orderPosition.getAmount(), false, …CODE_CREATE_PICK_POSITION`)
run FB-1-pos "L473 rebinds stockUnit to changeReservedAmount return value (exact: 1 rebind)" \
    bash -c "[ \$(grep -cE 'stockUnit\s*=\s*stockunitBusinessService\.changeReservedAmount\(\s*stockUnit\s*,\s*orderPosition\.getAmount\(\)\s*,\s*false\s*,\s*WmsConstants\.CODE_CREATE_PICK_POSITION' $ROJ 2>/dev/null) -eq 1 ]"

# NOTE: A per-line FB-1-neg negative check is intentionally omitted.
#       L473 (the fixedAssignments site) and L494 (the first pickFromOverstock loop) share
#       the IDENTICAL call shape `(stockUnit, orderPosition.getAmount(), false, CODE_CREATE_PICK_POSITION, ...)`.
#       A negative regex on that shape would also match the L494 SAFE call, producing a false
#       FAIL after Fix B is correctly applied. The combination of FB-1-pos (exactly 1 rebind)
#       and FB-2d-pos (exactly 3 bare calls remain) deterministically catches every regression:
#         - Fix B not applied  → FB-1-pos sees 0 rebinds → FAIL
#         - Fix B reverted     → FB-1-pos sees 0 rebinds → FAIL; FB-2d-pos sees 4 bare → FAIL
#         - Extra rebind added → FB-2d-pos sees 2 bare → FAIL
#         - SAFE callsite removed → FB-2a/b/c-pos line-anchor → FAIL

# POSITIVE (per-callsite regression guard, strengthened per critic M1):
# The three SAFE pickFromOverstock callsites at L494 (`orderPosition.getAmount()`),
# L518 (`available`), and L526 (`missing`) MUST each remain as bare statements.
# Tautological count threshold replaced with three precise per-line assertions.
run FB-2a-pos "L494 pickFromOverstock first-loop exact-match stays bare ('orderPosition.getAmount()' arg)" \
    file_contains '^\s+stockunitBusinessService\.changeReservedAmount\(\s*stockUnit\s*,\s*orderPosition\.getAmount\(\)\s*,\s*false\s*,\s*WmsConstants\.CODE_CREATE_PICK_POSITION' "$ROJ"

run FB-2b-pos "L518 pickFromOverstock second-loop partial-take stays bare ('available' arg)" \
    file_contains '^\s+stockunitBusinessService\.changeReservedAmount\(\s*stockUnit\s*,\s*available\s*,\s*false\s*,\s*WmsConstants\.CODE_CREATE_PICK_POSITION' "$ROJ"

run FB-2c-pos "L526 pickFromOverstock second-loop final-take stays bare ('missing' arg)" \
    file_contains '^\s+stockunitBusinessService\.changeReservedAmount\(\s*stockUnit\s*,\s*missing\s*,\s*false\s*,\s*WmsConstants\.CODE_CREATE_PICK_POSITION' "$ROJ"

# Total bare-call count == 3 — backup integrity check (catches future refactors that would violate the SAFE invariant).
# Known limitation: this regex requires the `stockunitBusinessService.changeReservedAmount(stockUnit` opening to be
# on a single line. If a future cleanup commit wraps any of L494/L518/L526 across newlines for readability, this
# check will falsely fail. The per-callsite anchors (FB-2a/b/c-pos) above each remain robust to internal-arg
# wrapping because they only require the `(stockUnit\s*,\s*<arg>` opening to be on one line; a typical wrap
# would split AFTER the opening paren, which still matches.
run FB-2d-pos "exactly 3 bare changeReservedAmount statements remain in ReleaseOrderJobService (L494, L518, L526)" \
    bash -c "[ \$(grep -cE '^\s+stockunitBusinessService\.changeReservedAmount\(\s*stockUnit' $ROJ 2>/dev/null) -eq 3 ]"

echo

# ===========================================================================
# Fix C — MobileReplenishServiceUnitTest regression test
# ===========================================================================
echo "── Fix C: MobileReplenishService regression test ───────────────────────"
echo

run FC-1-pos "MobileReplenishServiceUnitTest exists" \
    test -f "$MR_TEST"

run FC-2a-pos "L420-branch test 'finishReplenishmentOrder_rebindsSourceStockBeforeTransfer' exists" \
    file_contains 'finishReplenishmentOrder_rebindsSourceStockBeforeTransfer' "$MR_TEST"

run FC-2b-pos "L424 split-branch test 'finishReplenishmentOrder_splitBranch_rebindsSourceStockBeforeTransfer' exists" \
    file_contains 'finishReplenishmentOrder_splitBranch_rebindsSourceStockBeforeTransfer' "$MR_TEST"

run FC-3-pos "Tests use isSameAs (reference equality) — Stockunit has no @Override equals()" \
    file_contains 'isSameAs' "$MR_TEST"

# NEGATIVE: test must NOT use isEqualTo on Stockunit (would silently pass even without the fix)
run FC-3-neg "Tests do not use isEqualTo for the rebound-instance assertion" \
    file_not_contains 'assertThat\(transferCaptor\.getValue\(\)\)\.isEqualTo' "$MR_TEST"

# POSITIVE: tests use nullable(String.class) for the comment matcher (per critic C2 — null-safe matcher)
run FC-4-pos "Tests use nullable(String.class) for the null comment-parameter matcher" \
    file_contains 'nullable\(\s*String\.class\s*\)' "$MR_TEST"

# POSITIVE: tests drive the public entrypoint, not the private internal method
run FC-5-pos "Tests call the public entrypoint service.finishReplenishmentOrder(...) — not the private *Internal" \
    file_contains 'service\.finishReplenishmentOrder\(' "$MR_TEST"

run FC-5-neg "Tests do NOT call the private finishReplenishmentOrderInternal directly" \
    file_not_contains 'service\.finishReplenishmentOrderInternal\(' "$MR_TEST"

echo

# ===========================================================================
# Fix D — ReleaseOrderJobServiceUnitTest regression test
# ===========================================================================
echo "── Fix D: ReleaseOrderJobService regression test ───────────────────────"
echo

run FD-1-pos "ReleaseOrderJobServiceUnitTest exists" \
    test -f "$ROJ_TEST"

run FD-2-pos "Test method 'createPickingForOrder_rebindsStockUnitBeforeAvailableamountRead' exists" \
    file_contains 'createPickingForOrder_rebindsStockUnitBeforeAvailableamountRead' "$ROJ_TEST"

# POSITIVE: test drives the public releaseOrder(long, Map, Map) entrypoint
# (ReleaseOrderJobServiceUnitTest names its @InjectMocks field `releaseOrderJobService`,
#  not `service` — match either name to keep the assertion robust to test-class style.)
run FD-3-pos "Test calls .releaseOrder(...) public entrypoint" \
    file_contains '(service|releaseOrderJobService)\.releaseOrder\(' "$ROJ_TEST"

# POSITIVE: test uses isEqualByComparingTo for the BigDecimal assertion (scale-tolerant)
run FD-4-pos "Test uses isEqualByComparingTo for the BigDecimal fixAssignmentEntry[2] assertion" \
    file_contains 'isEqualByComparingTo' "$ROJ_TEST"

echo

# ===========================================================================
# Regression guards — service-level contract from 2351004 must remain intact
# ===========================================================================
echo "── Regression: 2351004 in-service contract is preserved ────────────────"
echo

run RG-1 "StockunitBusinessService.changeReservedAmount still detaches before lock" \
    file_contains 'entityManager\.detach\(\s*staleStockUnit\s*\)' "$SBS"

run RG-2 "StockunitBusinessService.changeReservedAmount still uses findByIdForUpdate" \
    file_contains 'findByIdForUpdate\(\s*staleStockUnit\.getId\(\)\s*\)' "$SBS"

run RG-3 "PickingorderBusinessService.confirmPick rebind from 2351004 preserved" \
    file_contains 'stockUnit\s*=\s*stockunitBusinessService\.changeReservedAmount\(\s*stockUnit' \
    "src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java"

run RG-4 "PickingorderBusinessServiceUnitTest rebind tests still in place" \
    file_contains 'confirmPick now rebinds stockUnit' "$PBS_TEST"

echo

# ===========================================================================
# Maven test runs (skip with SKIP_MVN=1)
# ===========================================================================
if [ "${SKIP_MVN:-0}" = "0" ]; then
    run M-1 "MobileReplenishServiceUnitTest passes" \
        mvn_test_passes "MobileReplenishServiceUnitTest"
    run M-2 "ReleaseOrderJobServiceUnitTest passes" \
        mvn_test_passes "ReleaseOrderJobServiceUnitTest"
    run M-3 "StockunitBusinessServiceUnitTest still passes (2351004 regression guard)" \
        mvn_test_passes "StockunitBusinessServiceUnitTest"
    run M-4 "PickingorderBusinessServiceUnitTest still passes (2351004 regression guard)" \
        mvn_test_passes "PickingorderBusinessServiceUnitTest"
else
    skip M-1 "MobileReplenishServiceUnitTest" "SKIP_MVN=1"
    skip M-2 "ReleaseOrderJobServiceUnitTest" "SKIP_MVN=1"
    skip M-3 "StockunitBusinessServiceUnitTest" "SKIP_MVN=1"
    skip M-4 "PickingorderBusinessServiceUnitTest" "SKIP_MVN=1"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
