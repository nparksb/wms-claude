#!/usr/bin/env bash
# verify-SBDEV-2229-transferStockToUnitLoad-toctou-lock-fix.sh
#
# Acceptance checks for SBDEV-2229: transferStockToUnitLoad TOCTOU entityLock fix.
#
# Run from the v2/wms2-api project root (default) or override PROJECT_ROOT:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2229-transferStockToUnitLoad-toctou-lock-fix.sh
#   $ PROJECT_ROOT=/path/to/v2/wms2-api bash ...

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
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

LOC_REPO="src/main/java/net/aim_ai/wms/repo/jpa/LocationRepository.java"
STK_SVC="src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java"
UL_SVC="src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java"
TEST_IT="src/test/java/net/aim_ai/wms/service/StockunitBusinessServiceConcurrencyIT.java"

echo
echo "verify-SBDEV-2229 — transferStockToUnitLoad TOCTOU entityLock fix"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# ── Fix A: LocationRepository.findByIdForUpdate ──────────────────────────────

check_A_method_exists() {
    grep -qE "findByIdForUpdate" "$LOC_REPO"
}
check_A_lock_annotation() {
    grep -qE "@Lock\s*\(.*PESSIMISTIC_WRITE" "$LOC_REPO"
}
check_A_jpql_query() {
    grep -qE "@Query\s*\(.*SELECT l FROM Location" "$LOC_REPO"
}
check_A_signature() {
    grep -qE "Optional<Location>\s+findByIdForUpdate\s*\(.*Long" "$LOC_REPO"
}

run A1  "Fix A: findByIdForUpdate method exists in LocationRepository"   check_A_method_exists
run A2  "Fix A: @Lock(PESSIMISTIC_WRITE) annotation present"             check_A_lock_annotation
run A3  "Fix A: JPQL @Query with SELECT l FROM Location"                 check_A_jpql_query
run A4  "Fix A: returns Optional<Location>, takes Long id"               check_A_signature
echo

# ── Fix B: StockunitBusinessService.transferStockToUnitLoad ──────────────────

check_B1_source_unitload_locked() {
    grep -qE "unitloadRepository\.findByIdForUpdate\s*\(\s*sourceStockunitUnitloadId" "$STK_SVC"
}
check_B2_source_location_locked() {
    grep -qE "locationRepository\.findByIdForUpdate\s*\(\s*sourceLocationId" "$STK_SVC"
}
check_B3_dest_stockunit_locked() {
    grep -qE "stockunitRepository\.findByIdForUpdate\s*\(\s*dstSuId" "$STK_SVC"
}
check_B4_dest_unitload_locked() {
    grep -qE "unitloadRepository\.findByIdForUpdate\s*\(\s*destinationUnitloadId" "$STK_SVC"
}
check_B5_dest_location_locked() {
    grep -qE "locationRepository\.findByIdForUpdate\s*\(\s*destinationLocationId" "$STK_SVC"
}

# NEGATIVE: the specific pre-fix unguarded loads must be gone.
check_B1_negative_source_unitload_findById_gone() {
    ! grep -qE "unitloadRepository\.findById\s*\(\s*sourceStockunitUnitloadId" "$STK_SVC"
}
check_B5_negative_dest_location_findById_gone() {
    ! grep -qE "locationRepository\.findById\s*\(\s*destinationUnitload\.getStoragelocationId\s*\(\s*\)" "$STK_SVC"
}

run B1  "Fix B: sourceUnitload acquired via findByIdForUpdate"           check_B1_source_unitload_locked
run B2  "Fix B: sourceLocation acquired via findByIdForUpdate"           check_B2_source_location_locked
run B3  "Fix B: destinationStockUnit acquired via findByIdForUpdate"     check_B3_dest_stockunit_locked
run B4  "Fix B: destinationUnitload acquired via findByIdForUpdate"      check_B4_dest_unitload_locked
run B5  "Fix B: destinationLocation acquired via findByIdForUpdate"      check_B5_dest_location_locked
run B1- "Fix B NEG: old unitloadRepository.findById(sourceStockunitUnitloadId) gone"  check_B1_negative_source_unitload_findById_gone
run B5- "Fix B NEG: old locationRepository.findById(destinationUnitload.getStoragelocationId()) gone"  check_B5_negative_dest_location_findById_gone
echo

# ── Fix C: UnitloadBusinessService.transferUnitLoadToLocation ────────────────

check_C1_dest_location_locked() {
    # Fix C uses conditional lock (only when !ignoreLock) to avoid nirvana-location serialization
    grep -qE "locationRepository\.findByIdForUpdate\s*\(\s*destinationLocationId" "$UL_SVC"
}
# NEGATIVE: ensure the caller-passed destinationLocation isn't read for entityLock before the locked re-fetch.
# Heuristic: find the line numbers of the new findByIdForUpdate and the entityLock read; the former must precede the latter.
check_C1_lock_before_entitylock_check() {
    local lock_line entitylock_line
    lock_line=$(grep -nE "locationRepository\.findByIdForUpdate\s*\(\s*destinationLocationId" "$UL_SVC" | head -n1 | cut -d: -f1)
    entitylock_line=$(grep -nE "destinationLocation\.getEntityLock\s*\(\s*\)" "$UL_SVC" | head -n1 | cut -d: -f1)
    [ -n "$lock_line" ] && [ -n "$entitylock_line" ] && [ "$lock_line" -lt "$entitylock_line" ]
}

run C1  "Fix C: destinationLocation acquired via findByIdForUpdate"      check_C1_dest_location_locked
run C1+ "Fix C: locked re-fetch precedes destinationLocation.getEntityLock() read" check_C1_lock_before_entitylock_check
echo

# ── Concurrency IT exists ────────────────────────────────────────────────────

check_it_exists() {
    [ -f "$TEST_IT" ]
}
check_it_uses_countdownlatch() {
    grep -qE "CountDownLatch" "$TEST_IT"
}
check_it_asserts_concurrency() {
    grep -qE "transferStockToUnitLoad|BusinessException" "$TEST_IT"
}

run T1  "IT: StockunitBusinessServiceConcurrencyIT.java exists"          check_it_exists
run T2  "IT: test uses CountDownLatch"                                   check_it_uses_countdownlatch
run T3  "IT: test exercises transferStockToUnitLoad / BusinessException" check_it_asserts_concurrency
echo

# ── PessimisticLockException handler in RestExceptionHandler ─────────────────────────────────

EXCEPTION_HANDLER="src/main/java/net/aim_ai/wms/exceptions/RestExceptionHandler.java"

check_H1_pessimistic_lock_handler() {
    # Matches both Spring DAO wrapper (PessimisticLockingFailureException) and JPA exception (PessimisticLockException)
    grep -qE "PessimisticLockingFailureException|PessimisticLockException|LockTimeoutException" "$EXCEPTION_HANDLER"
}

run H1 "Handler: RestExceptionHandler handles PessimisticLockingFailureException or LockTimeoutException" check_H1_pessimistic_lock_handler
echo

# ── Run targeted unit tests ──────────────────────────────────────────────────

run UT1 "Unit tests pass (StockunitBusinessServiceUnitTest)" \
    mvn test -Dtest=StockunitBusinessServiceUnitTest -DfailIfNoTests=false -q
run UT2 "Unit tests pass (UnitloadBusinessServiceUnitTest)" \
    mvn test -Dtest=UnitloadBusinessServiceUnitTest -DfailIfNoTests=false -q
echo

echo "Result: $PASS pass, $FAIL fail"
echo
[ "$FAIL" -eq 0 ]
