#!/usr/bin/env bash
# verify-SBDEV-2234-replenishment-maintenance-tx-and-lock.sh
#
# Acceptance checks for SBDEV-2234: ReplenishmentOrderMaintenanceService
# concurrency hardening (Fix A @Transactional, Fix B findByIdForUpdate,
# Fix C sysprop-persisted lastRun cadence).
#
# Run from the v2/wms2-api project root (default) or override PROJECT_ROOT:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2234-replenishment-maintenance-tx-and-lock.sh
#   $ PROJECT_ROOT=/path/to/v2/wms2-api bash ...
#
# Skip mvn tests on slow local dev runs with:
#   $ SKIP_MVN_TESTS=1 bash sbdocs/9-System/scripts/verify-SBDEV-2234-...

set -u

# Ensure sdkman-managed maven is on PATH when run from a non-interactive shell
export PATH="$HOME/.sdkman/candidates/maven/current/bin:$PATH"

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    local id=$1 desc=$2 reason=$3
    printf "  SKIP  %-10s  %s  (%s)\n" "$id" "$desc" "$reason"
    SKIP=$((SKIP+1))
}

file_contains()     { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }

SVC="src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java"
SYSPROP_SVC="src/main/java/net/aim_ai/wms/service/SyspropService.java"
CONSTANTS="src/main/java/net/aim_ai/wms/service/WmsConstants.java"
REPO="src/main/java/net/aim_ai/wms/repo/jpa/ReplenishorderRepository.java"
SVC_PKG="src/main/java/net/aim_ai/wms/service"
UNIT_TEST="src/test/java/net/aim_ai/wms/unit/service/ReplenishmentOrderMaintenanceServiceUnitTest.java"
IT_TEST="src/test/java/net/aim_ai/wms/integration/service/ReplenishmentOrderMaintenanceServiceIntegrationTest.java"

echo
echo "verify-SBDEV-2234 — ReplenishmentOrderMaintenanceService concurrency hardening"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# ── Fix A: @Transactional on recalculateForItem ONLY (not recalculateOpenOrders) ─

check_A1_recalcForItem_has_transactional() {
    # @Transactional...tenantTransactionManager appears within ~5 lines above 'recalculateForItem(Long'
    grep -B5 -E "public void recalculateForItem\s*\(\s*Long" "$SVC" 2>/dev/null \
        | grep -qE "@Transactional\s*\([^)]*tenantTransactionManager"
}

check_A2_recalcForItem_rollbackFor() {
    grep -B5 -E "public void recalculateForItem\s*\(\s*Long" "$SVC" 2>/dev/null \
        | grep -qE "rollbackFor\s*=\s*\{[^}]*(BusinessException|FacadeException)"
}

check_A3_recalcOpenOrders_NOT_transactional() {
    # The recalculateOpenOrders(boolean) MUST remain non-transactional per 260331.
    # Assert no @Transactional appears in the 5 lines immediately above the signature.
    ! grep -B5 -E "public void recalculateOpenOrders\s*\(\s*boolean" "$SVC" 2>/dev/null \
        | grep -qE "@Transactional"
}

run A1  "Fix A: recalculateForItem has @Transactional(tenantTransactionManager)" check_A1_recalcForItem_has_transactional
run A2  "Fix A: recalculateForItem rolls back on BusinessException/FacadeException" check_A2_recalcForItem_rollbackFor
run A3  "Fix A NEG: recalculateOpenOrders(boolean) is NOT @Transactional"        check_A3_recalcOpenOrders_NOT_transactional

# ── Fix A.1: null-itemDataId guard (architect-required) ───────────────────────
#
# After Fix A wraps recalculateForItem in @Transactional, the original
# `if (itemDataId == null) { recalculateOpenOrders(); return; }` would route
# the 600+ row sweep into the new transaction, violating the 260331 decision
# to keep recalculateOpenOrders non-transactional. Fix A.1 changes the null
# branch to an early-return + LOG.warn. This check asserts:
#   1. The null guard is present (`if (itemDataId == null)` or equivalent).
#   2. The null branch contains `return` and `LOG.warn`.
#   3. The null branch does NOT call `recalculateOpenOrders` anymore.
check_A4_null_branch_early_return_with_warn() {
    # Capture the lines from the `if (itemDataId == null)` line to the matching
    # close brace (heuristic: 8 lines is more than enough for this small block).
    local block
    block=$(grep -A8 -E "if\s*\(\s*itemDataId\s*==\s*null\s*\)" "$SVC" 2>/dev/null) || return 1
    # Must contain return + LOG.warn
    echo "$block" | grep -qE "return\s*;" \
        && echo "$block" | grep -qE "LOG\.warn"
}

check_A4_null_branch_does_not_call_sweep() {
    # The null branch must NOT call recalculateOpenOrders anymore.
    # We scan the 8 lines following the null-check; if any of them invoke
    # recalculateOpenOrders(...), the guard has regressed.
    ! grep -A8 -E "if\s*\(\s*itemDataId\s*==\s*null\s*\)" "$SVC" 2>/dev/null \
        | grep -qE "recalculateOpenOrders\s*\("
}

run A4  "Fix A.1: null-itemDataId branch is early-return + LOG.warn"          check_A4_null_branch_early_return_with_warn
run A4N "Fix A.1 NEG: null branch does NOT call recalculateOpenOrders()"      check_A4_null_branch_does_not_call_sweep

# ── Negative: no runtime tx-active assertion in recalculateOrder ──────────────
#
# Per §10 resolved decision #6, recalculateOrder MUST NOT contain a runtime
# Assert.state(... isActualTransactionActive() ...) — that would break the
# recalculateOpenOrders sweep path which intentionally calls recalculateOrder
# outside any tx.
check_A5_no_isActualTransactionActive_assertion() {
    ! grep -qE "isActualTransactionActive" "$SVC"
}

run A5  "Fix B/A NEG: no Assert.state(isActualTransactionActive) in service"   check_A5_no_isActualTransactionActive_assertion
echo

# ── Fix B: findByIdForUpdate in recalculateOrder re-fetch ─────────────────────

check_B1_findByIdForUpdate_used() {
    grep -qE "replenishorderRepository\.findByIdForUpdate\s*\(\s*order\.getId\s*\(\s*\)" "$SVC"
}

check_B2_old_findById_refetch_gone() {
    # The original plain findById(order.getId()) call must be gone from the re-fetch site.
    ! grep -qE "replenishorderRepository\.findById\s*\(\s*order\.getId\s*\(\s*\)" "$SVC"
}

check_B3_repo_method_exists() {
    grep -qE "Optional<Replenishorder>\s+findByIdForUpdate\s*\(" "$REPO"
}

check_B4_repo_lock_annotation() {
    grep -qE "@Lock\s*\(.*PESSIMISTIC_WRITE" "$REPO"
}

run B1  "Fix B: replenishorderRepository.findByIdForUpdate(order.getId()) used" check_B1_findByIdForUpdate_used
run B2  "Fix B NEG: old replenishorderRepository.findById(order.getId()) re-fetch gone" check_B2_old_findById_refetch_gone
run B3  "Fix B: findByIdForUpdate method exists in ReplenishorderRepository"   check_B3_repo_method_exists
run B4  "Fix B: @Lock(PESSIMISTIC_WRITE) on repository method"                  check_B4_repo_lock_annotation
echo

# ── Fix C: sysprop-persisted lastRun cadence ──────────────────────────────────

check_C1_sysprop_key_constant() {
    grep -qE "SYSTEM_PROPERTY_REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS_KEY" "$CONSTANTS"
}

check_C2_sysprop_default_constant() {
    grep -qE "SYSTEM_PROPERTY_REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS_DEFAULT_VALUE" "$CONSTANTS"
}

check_C3_lastRun_field_removed() {
    ! grep -qE "private\s+Instant\s+lastRun" "$SVC"
}

check_C4_service_uses_setSysvalue() {
    grep -qE "syspropService\.setSysvalue\s*\(" "$SVC"
}

check_C5_service_uses_getSysvalue_for_lastrun() {
    # service must read the new key from syspropService
    grep -qE "SYSTEM_PROPERTY_REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS_KEY" "$SVC"
}

check_C6_syspropService_setSysvalue_exists() {
    grep -qE "public\s+void\s+setSysvalue\s*\(\s*String\s+key\s*,\s*String\s+value" "$SYSPROP_SVC"
}

check_C7_syspropService_setSysvalue_evicts() {
    # Verify the new setSysvalue method has @CacheEvict (look for both annotation and method within 10 lines)
    grep -B2 -A10 -E "public\s+void\s+setSysvalue\s*\(\s*String\s+key" "$SYSPROP_SVC" 2>/dev/null \
        | grep -qE "@CacheEvict" \
    && grep -B5 -E "public\s+void\s+setSysvalue\s*\(\s*String\s+key" "$SYSPROP_SVC" 2>/dev/null \
        | grep -qE "@CacheEvict"
}

check_C8_syspropService_setSysvalue_transactional() {
    grep -B5 -E "public\s+void\s+setSysvalue\s*\(\s*String\s+key" "$SYSPROP_SVC" 2>/dev/null \
        | grep -qE "@Transactional\s*\([^)]*tenantTransactionManager"
}

run C1  "Fix C: sysprop key constant present"                                   check_C1_sysprop_key_constant
run C2  "Fix C: sysprop default-value constant present"                         check_C2_sysprop_default_constant
run C3  "Fix C NEG: private Instant lastRun field removed"                      check_C3_lastRun_field_removed
run C4  "Fix C: service writes lastRun via syspropService.setSysvalue"          check_C4_service_uses_setSysvalue
run C5  "Fix C: service references the new sysprop key constant"                check_C5_service_uses_getSysvalue_for_lastrun
run C6  "Fix C: SyspropService.setSysvalue(String,String) added"                check_C6_syspropService_setSysvalue_exists
run C7  "Fix C: SyspropService.setSysvalue has @CacheEvict on sysprops cache"   check_C7_syspropService_setSysvalue_evicts
run C8  "Fix C: SyspropService.setSysvalue is @Transactional(tenantTransactionManager)" check_C8_syspropService_setSysvalue_transactional
echo

# ── AC-5: No `synchronized` keyword on any class in service package ───────────

check_audit_no_synchronized_in_service_pkg() {
    # Scan all .java files in the service package (incl. subpackages). Allow zero matches.
    # Match `synchronized` as a Java keyword (word boundary), ignore string literals heuristically by
    # excluding lines that start with `*` (javadoc) and lines containing `"synchronized"`.
    local hits
    hits=$(grep -rn --include='*.java' -E '\bsynchronized\b' "$SVC_PKG" 2>/dev/null \
        | grep -v '^\s*\*' \
        | grep -v '"synchronized"' \
        | wc -l \
        | tr -d ' ')
    [ "$hits" = "0" ]
}

run AUD "AC-5: zero 'synchronized' keyword usage in service/ package"           check_audit_no_synchronized_in_service_pkg
echo

# ── Optional: test classes present ────────────────────────────────────────────

check_unit_test_exists() {
    [ -f "$UNIT_TEST" ]
}

check_it_test_exists() {
    [ -f "$IT_TEST" ]
}

check_it_uses_countdownlatch() {
    [ -f "$IT_TEST" ] && grep -qE "CountDownLatch" "$IT_TEST"
}

run T1  "Test: ReplenishmentOrderMaintenanceServiceUnitTest.java present"       check_unit_test_exists
run T2  "Test: ReplenishmentOrderMaintenanceServiceIntegrationTest.java present" check_it_test_exists
run T3  "Test IT uses CountDownLatch for the two-thread concurrency test"        check_it_uses_countdownlatch
echo

# ── Run targeted JUnit tests ──────────────────────────────────────────────────

if [ "${SKIP_MVN_TESTS:-0}" = "1" ]; then
    skip MV1 "Unit tests pass (ReplenishmentOrderMaintenanceServiceUnitTest)" "SKIP_MVN_TESTS=1"
else
    run MV1 "Unit tests pass (ReplenishmentOrderMaintenanceServiceUnitTest)" \
        mvn test -Dtest=ReplenishmentOrderMaintenanceServiceUnitTest -DfailIfNoTests=false -q
fi
echo

echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
echo
[ "$FAIL" -eq 0 ]
