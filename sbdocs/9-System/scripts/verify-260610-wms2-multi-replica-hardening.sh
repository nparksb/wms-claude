#!/usr/bin/env bash
# verify-260610-wms2-multi-replica-hardening.sh — machine-checkable acceptance for
# "WMS2 Multi-Replica Hardening — OptimisticLockRetry / JWT Decoder / HTTP-in-Tx Guard"
#
# Plan: sbdocs/1-Projects/wms2/plan/260610-wms2-multi-replica-hardening.md
# Three independent phases (A → B → C), each with positive + negative checks.
#
#   $ bash sbdocs/9-System/scripts/verify-260610-wms2-multi-replica-hardening.sh
#   $ RUN_MVN=1 bash ...   # additionally run the targeted JUnit suites (slow)
#
# Exit code 0 only when every (non-skipped) check passes. Run BEFORE
# implementation to capture the FAIL baseline and AFTER each phase.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

RUN_MVN="${RUN_MVN:-0}"

MAIN=src/main/java/net/aim_ai/wms
TEST=src/test/java/net/aim_ai/wms

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1
    local desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"
        PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"
        FAIL=$((FAIL+1))
    fi
}

skip() {
    local id=$1
    local desc=$2
    local reason=$3
    printf "  SKIP  %-10s  %s  (%s)\n" "$id" "$desc" "$reason"
    SKIP=$((SKIP+1))
}

file_contains() { grep -qE "$1" "$2"; }
file_not_contains() { [ -f "$2" ] && ! grep -qE "$1" "$2"; }

mvn_test_passes() {
    local test_class=$1
    mvn test -Dtest="$test_class" -DfailIfNoTests=false -q 2>&1 | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0"
}

# === Phase A — inert OptimisticLockRetry cleanup ==============================

check_a_retry_removed_picking() {
    file_not_contains 'optimisticLockRetry|executeWithRetry|OptimisticLockRetry' \
        "$MAIN/service/PickingorderBusinessService.java"
}

check_a_save_present_picking() {
    # the collapse must leave a post-mutation save (the lambda's save was the only one)
    file_contains 'pickingorderPositionRepository\.save\(pickingPosition\)' \
        "$MAIN/service/PickingorderBusinessService.java"
}

check_a_retry_removed_unitload() {
    file_not_contains 'optimisticLockRetry|executeWithRetry|OptimisticLockRetry' \
        "$MAIN/service/UnitloadBusinessService.java"
}

check_a_clear_carrier_kept() {
    file_contains 'setCarrierunitloadId\(null\)' \
        "$MAIN/service/UnitloadBusinessService.java"
}

check_a_injection_removed_replenish() {
    file_not_contains 'OptimisticLockRetry|optimisticLockRetry' \
        "$MAIN/service/mobile/MobileReplenishService.java"
}

check_a_palletizing_kept() {
    file_contains 'optimisticLockRetry\.executeWithRetry' \
        "$MAIN/service/mobile/MobilePalletizingService.java"
}

check_a_utility_kept() {
    [ -f "$MAIN/util/OptimisticLockRetry.java" ] && [ -f "$TEST/unit/util/OptimisticLockRetryTest.java" ]
}

check_a_test_deleted() {
    ! grep -rqn "shouldHandleOptimisticLockingException" src/test
}

check_a_mocks_dropped() {
    file_not_contains 'OptimisticLockRetry' "$TEST/unit/service/PickingorderBusinessServiceUnitTest.java" \
    && file_not_contains 'OptimisticLockRetry' "$TEST/unit/service/UnitloadBusinessServiceUnitTest.java"
}

# === Phase B — MultiTenantJwtDecoder Caffeine TTL =============================

JWT_DECODER="$MAIN/landlord/config/MultiTenantJwtDecoder.java"

check_b_no_concurrenthashmap() {
    file_not_contains 'ConcurrentHashMap' "$JWT_DECODER"
}

check_b_caffeine_present() {
    file_contains 'Caffeine\.newBuilder\(\)' "$JWT_DECODER"
}

check_b_ttl_24h() {
    file_contains 'expireAfterWrite\(Duration\.ofHours\(24\)\)' "$JWT_DECODER"
}

check_b_maxsize() {
    file_contains 'maximumSize\(' "$JWT_DECODER"
}

check_b_no_rebuild() {
    # TTL-only v1: no invalidate-and-rebuild-on-JwtException CODE path.
    # (Comment-safe: the prescribed comment mentions "rebuild", so match only
    # actual cache-invalidation calls, not the word.)
    file_not_contains 'jwtDecoders\.invalidate|\.invalidateAll\(|asMap\(\)\.remove' "$JWT_DECODER"
}

check_b_test_exists() {
    [ -f "$TEST/unit/config/MultiTenantJwtDecoderUnitTest.java" ]
}

check_b_test_seam() {
    # Architect A1: the build-count assertions must use the mockStatic seam, not live JWKS
    file_contains 'mockStatic\(NimbusJwtDecoder\.class\)' \
        "$TEST/unit/config/MultiTenantJwtDecoderUnitTest.java"
}

check_b_readme_reconciled() {
    # README must list the class AND its claimed per-class count must equal the
    # shipped @Test count (no phantom claims).
    local readme="$TEST/unit/config/README.md"
    local testfile="$TEST/unit/config/MultiTenantJwtDecoderUnitTest.java"
    [ -f "$readme" ] && [ -f "$testfile" ] || return 1
    local actual
    actual=$(grep -c "@Test" "$testfile")
    grep -E "MultiTenantJwtDecoderUnitTest" "$readme" | grep -qE "(^|[^0-9])${actual}([^0-9]|$)"
}

# === Phase C — HTTP-in-tx regression guard ====================================

ARCH_TEST="$TEST/unit/config/HttpInTransactionArchTest.java"

check_c_guard_exists() {
    [ -f "$ARCH_TEST" ]
}

check_c_guard_targets() {
    file_contains 'HttpRestService' "$ARCH_TEST" \
    && file_contains 'Transactional' "$ARCH_TEST" \
    && file_contains 'getMethodCallsFromSelf' "$ARCH_TEST"
}

check_c_spring_annotation_only() {
    # Architect A6: guard keys on Spring's @Transactional; the rule is only sound
    # while no jakarta.transaction.Transactional usage exists in main.
    ! grep -rqn 'jakarta\.transaction\.Transactional' "$MAIN"
}

# === Runner ===================================================================

echo
echo "verify-260610-wms2-multi-replica-hardening — running acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo
echo "Phase A — OptimisticLockRetry cleanup"
run A-pick      "inert retry + injection gone from PickingorderBusinessService"   check_a_retry_removed_picking
run A-pick-save "post-mutation save(pickingPosition) present (Architect A2)"      check_a_save_present_picking
run A-ul        "inert retry + injection gone from UnitloadBusinessService"       check_a_retry_removed_unitload
run A-ul-clear  "setCarrierunitloadId(null) retained"                             check_a_clear_carrier_kept
run A-repl      "dead injection gone from MobileReplenishService"                 check_a_injection_removed_replenish
run A-pall      "working consumer kept in MobilePalletizingService"               check_a_palletizing_kept
run A-util      "OptimisticLockRetry utility + its test kept"                     check_a_utility_kept
run A-test      "shouldHandleOptimisticLockingException deleted"                  check_a_test_deleted
run A-mocks     "@Mock OptimisticLockRetry dropped from the two trimmed tests"    check_a_mocks_dropped

echo
echo "Phase B — MultiTenantJwtDecoder Caffeine TTL"
run B-nochm     "ConcurrentHashMap removed"                                       check_b_no_concurrenthashmap
run B-caffeine  "Caffeine.newBuilder() present"                                   check_b_caffeine_present
run B-ttl       "expireAfterWrite(Duration.ofHours(24))"                          check_b_ttl_24h
run B-maxsize   "maximumSize bound present"                                       check_b_maxsize
run B-norebuild "no rebuild-on-exception path (TTL-only v1)"                      check_b_no_rebuild
run B-test      "MultiTenantJwtDecoderUnitTest exists"                            check_b_test_exists
run B-seam      "test uses mockStatic(NimbusJwtDecoder) seam (Architect A1)"      check_b_test_seam
run B-readme    "unit/config/README.md count matches shipped @Test count"         check_b_readme_reconciled

echo
echo "Phase C — HTTP-in-tx regression guard"
run C-exists    "HttpInTransactionArchTest exists"                                check_c_guard_exists
run C-shape     "guard targets @Transactional -> HttpRestService calls"           check_c_guard_targets
run C-springtx  "no jakarta.transaction.Transactional in main (A6 assumption)"    check_c_spring_annotation_only

echo
if [ "$RUN_MVN" = "1" ]; then
    echo "Targeted JUnit suites (RUN_MVN=1)"
    run A-mvn  "Phase A touched suites pass"  mvn_test_passes "PickingorderBusinessServiceUnitTest,UnitloadBusinessServiceUnitTest,MobilePalletizingServiceUnitTest,OptimisticLockRetryTest"
    run B-mvn  "MultiTenantJwtDecoderUnitTest passes"  mvn_test_passes "MultiTenantJwtDecoderUnitTest"
    run C-mvn  "HttpInTransactionArchTest passes on clean tree"  mvn_test_passes "HttpInTransactionArchTest"
else
    skip A-mvn "Phase A touched suites pass"               "set RUN_MVN=1 to execute"
    skip B-mvn "MultiTenantJwtDecoderUnitTest passes"      "set RUN_MVN=1 to execute"
    skip C-mvn "HttpInTransactionArchTest passes"          "set RUN_MVN=1 to execute"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
