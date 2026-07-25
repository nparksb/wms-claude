#!/usr/bin/env bash
# verify-SBDEV-2223-confirmPick-last-pick-detection-race.sh
#
# Acceptance checks for SBDEV-2223: confirmPick last-pick detection race.
#
# Run from the v2/wms2-api project root (default) or override PROJECT_ROOT:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2223-confirmPick-last-pick-detection-race.sh
#   $ PROJECT_ROOT=/path/to/v2/wms2-api bash ...

set -u

PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

REPO="src/main/java/net/aim_ai/wms/repo/jpa/CustomerorderPositionRepository.java"
SVC="src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java"
TEST_UNIT="src/test/java/net/aim_ai/wms/unit/service/PickingorderBusinessServiceUnitTest.java"
TEST_IT="src/test/java/net/aim_ai/wms/service/PickingorderBusinessServiceConcurrencyIT.java"

echo
echo "verify-SBDEV-2223 — confirmPick last-pick detection race"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# ── Fix A: new repository method ─────────────────────────────────────────────

check_A_method_exists() {
    grep -qE "findByOrderIdForUpdate" "$REPO"
}
check_A_lock_annotation() {
    grep -qE "@Lock\s*\(.*PESSIMISTIC_WRITE" "$REPO"
}
check_A_jpql_query() {
    grep -qE "@Query\s*\(.*SELECT cp FROM CustomerorderPosition" "$REPO"
}
check_A_order_by() {
    grep -qE "ORDER BY cp\.id" "$REPO"
}
check_A_lock_import() {
    grep -qE "import org\.springframework\.data\.jpa\.repository\.Lock" "$REPO"
}
check_A_lockmode_import() {
    grep -qE "import jakarta\.persistence\.LockModeType" "$REPO"
}

run A1  "Fix A: findByOrderIdForUpdate method exists in repository"  check_A_method_exists
run A2  "Fix A: @Lock(PESSIMISTIC_WRITE) annotation present"          check_A_lock_annotation
run A3  "Fix A: JPQL @Query with SELECT cp FROM CustomerorderPosition" check_A_jpql_query
run A4  "Fix A: ORDER BY cp.id in JPQL (deterministic lock order)"     check_A_order_by
run A5  "Fix A: Lock import present"                                   check_A_lock_import
run A6  "Fix A: LockModeType import present"                           check_A_lockmode_import
echo

# ── Fix B: confirmPick call-site (line ~529) ──────────────────────────────────

check_B_locked_call() {
    # confirmPick must call the locked variant
    grep -qE "findByOrderIdForUpdate" "$SVC"
}
check_B_unlocked_gone_in_confirmPick() {
    # The old unlocked call must NOT appear inside the hasAllPicked block.
    # Strategy: check that findByOrderId (no ForUpdate) does not appear between
    # "hasAllPicked" context and "findByOrderIdForUpdate" introduction.
    # Simpler: count occurrences of bare findByOrderId in the service.
    # After fix, confirmPick and finishPickingOrder should have 0 bare calls;
    # only cleanUpCancelledOrder (:346) keeps the unlocked form.
    local bare_count
    bare_count=$(grep -cE "findByOrderId\b" "$SVC" 2>/dev/null || echo 0)
    # Expect exactly 1 remaining bare call (cleanUpCancelledOrder:346)
    [ "$bare_count" -eq 1 ]
}

run B1  "Fix B: findByOrderIdForUpdate called in service"              check_B_locked_call
run B2  "Fix B: bare findByOrderId reduced to 1 (cleanUpCancelledOrder only)" check_B_unlocked_gone_in_confirmPick
echo

# ── Fix C: finishPickingOrder call-site (line ~223) ───────────────────────────
# Covered by B1+B2 above (both substitutions reduce the bare-call count to 1).
# Additional: verify the finishPickingOrder section contains the locked call.

check_C_locked_in_finishPickingOrder() {
    # Extract lines of finishPickingOrder and verify findByOrderIdForUpdate appears there.
    # Proxy: both confirmPick and finishPickingOrder use the new method — at least 2 occurrences.
    local locked_count
    locked_count=$(grep -cE "findByOrderIdForUpdate" "$SVC" 2>/dev/null || echo 0)
    [ "$locked_count" -ge 2 ]
}

run C1  "Fix C: findByOrderIdForUpdate appears at least twice in service (both sites)" check_C_locked_in_finishPickingOrder
echo

# ── Stub migration: 17 stubs migrated ────────────────────────────────────────

check_stubs_migrated() {
    # After migration, the unit test should have findByOrderIdForUpdate stubs.
    grep -qE "findByOrderIdForUpdate" "$TEST_UNIT"
}
check_stubs_bare_count() {
    # Only 4 bare findByOrderId stubs remain (CleanUp* test classes).
    local bare_count
    bare_count=$(grep -cE "\.findByOrderId\b" "$TEST_UNIT" 2>/dev/null || echo 99)
    [ "$bare_count" -le 4 ]
}

run S1  "Stubs: findByOrderIdForUpdate stubs present in unit test"     check_stubs_migrated
run S2  "Stubs: bare findByOrderId stubs reduced to ≤4 in unit test"   check_stubs_bare_count
echo

# ── Mockito verify assertions ────────────────────────────────────────────────

check_verify_locked() {
    grep -qE "verify.*findByOrderIdForUpdate" "$TEST_UNIT"
}
check_verify_never_unlocked() {
    grep -qE "never\(\).*findByOrderId\b|findByOrderId.*never\(\)" "$TEST_UNIT"
}

run V1  "Verify: verify(repo).findByOrderIdForUpdate assertion exists"  check_verify_locked
run V2  "Verify: verify(repo, never()).findByOrderId assertion exists"  check_verify_never_unlocked
echo

# ── Concurrency IT exists ─────────────────────────────────────────────────────

check_it_exists() {
    [ -f "$TEST_IT" ]
}
check_it_uses_countdownlatch() {
    grep -qE "CountDownLatch" "$TEST_IT"
}
check_it_asserts_picked() {
    grep -qE "PICKED|600" "$TEST_IT"
}

run IT1 "IT: PickingorderBusinessServiceConcurrencyIT.java exists"      check_it_exists
run IT2 "IT: test uses CountDownLatch"                                   check_it_uses_countdownlatch
run IT3 "IT: test asserts PICKED state"                                  check_it_asserts_picked
echo

# ── Run targeted unit tests ───────────────────────────────────────────────────

run UT  "Unit tests pass (PickingorderBusinessServiceUnitTest)" \
    mvn test -Dtest=PickingorderBusinessServiceUnitTest -DfailIfNoTests=false -q
echo

echo "Result: $PASS pass, $FAIL fail"
echo
[ "$FAIL" -eq 0 ]
