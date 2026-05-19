#!/usr/bin/env bash
# verify-SBDEV-2235-sku-rest-partial-batch-atomicity.sh
#
# Acceptance checks for SBDEV-2235: SkuRestController.update / create
# partial-batch atomicity. Validates that:
#   - SkuBatchCreateUpdateService exists with the correct @Transactional shape
#   - The controller no longer auto-commits individual itemdataRepository.save() calls
#   - The self-recursion update()->create() at line 230 is deleted
#   - The line 275 Optional.get() NPE (NoSuchElementException) is deleted
#   - Validation failures return 422 (not 400) on /update and /create
#   - /delete still returns 400 (scope boundary)
#   - @CacheEvict(allEntries=true) remains on both controller upsert methods
#   - messageService.create* is NOT called from inside SkuBatchCreateUpdateService
#
# Run from the v2/wms2-api project root (default) or override PROJECT_ROOT:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2235-sku-rest-partial-batch-atomicity.sh
#   $ PROJECT_ROOT=/path/to/v2/wms2-api bash ...

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

# Locate mvn: prefer explicit override, then SDKMAN, then PATH
MVN="${MVN:-}"
if [ -z "$MVN" ]; then
    for candidate in \
        "$HOME/.sdkman/candidates/maven/current/bin/mvn" \
        "$(find "$HOME/.sdkman/candidates/maven" -name mvn -maxdepth 4 2>/dev/null | sort -V | tail -1)" \
        "$(command -v mvn 2>/dev/null)"; do
        [ -x "$candidate" ] && { MVN="$candidate"; break; }
    done
fi
[ -z "$MVN" ] && { echo "FATAL: mvn not found — set MVN=/path/to/mvn"; exit 2; }

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

SERVICE="src/main/java/net/aim_ai/wms/service/SkuBatchCreateUpdateService.java"
CONTROLLER="src/main/java/net/aim_ai/wms/controller/rest/SkuRestController.java"
SERVICE_TEST="src/test/java/net/aim_ai/wms/unit/service/SkuBatchCreateUpdateServiceUnitTest.java"
CONTROLLER_TEST="src/test/java/net/aim_ai/wms/unit/controller/rest/SkuRestControllerUnitTest.java"
IT_TEST="src/test/java/net/aim_ai/wms/integration/SkuRestControllerAtomicityIntegrationTest.java"

echo
echo "verify-SBDEV-2235 — SkuRestController partial-batch atomicity"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# ── AC1-AC6: SkuBatchCreateUpdateService presence & shape ───────────────────

check_AC1_service_exists() {
    [ -f "$SERVICE" ]
}
check_AC2_service_annotated() {
    grep -qE "^@Service\b" "$SERVICE"
}
check_AC3_transactional_with_tenant_manager() {
    grep -Pzo "(?s)@Transactional\s*\([^)]*value\s*=\s*\"tenantTransactionManager\"" "$SERVICE" >/dev/null
}
check_AC4_rollback_for_wsbce() {
    grep -Pzo "(?s)@Transactional\s*\([^)]*rollbackFor\s*=[^)]*WebserviceBusinessExceptionClientSide\.class" "$SERVICE" >/dev/null
}
check_AC5_rollback_for_business_exception() {
    grep -Pzo "(?s)@Transactional\s*\([^)]*rollbackFor\s*=[^)]*BusinessException\.class" "$SERVICE" >/dev/null
}
check_AC6_constructor_injection_no_autowired_field() {
    ! grep -Pzo "(?s)@Autowired\s*\n\s*private\s+\w" "$SERVICE" >/dev/null
}

run AC1  "Service: SkuBatchCreateUpdateService.java exists"                      check_AC1_service_exists
run AC2  "Service: annotated @Service"                                           check_AC2_service_annotated
run AC3  "Service: @Transactional(value = \"tenantTransactionManager\")"         check_AC3_transactional_with_tenant_manager
run AC4  "Service: rollbackFor includes WebserviceBusinessExceptionClientSide.class" check_AC4_rollback_for_wsbce
run AC5  "Service: rollbackFor includes BusinessException.class (forward-compat)" check_AC5_rollback_for_business_exception
run AC6  "Service: constructor injection (no @Autowired field)"                  check_AC6_constructor_injection_no_autowired_field
echo

# ── AC7-AC8: Controller wiring ───────────────────────────────────────────────

check_AC7_controller_injects_service() {
    grep -qE "SkuBatchCreateUpdateService\s+\w+" "$CONTROLLER"
}
check_AC8_controller_invokes_upsert_all() {
    grep -qE "skuBatchCreateUpdateService\.upsertAll\s*\(" "$CONTROLLER"
}

run AC7  "Controller: SkuBatchCreateUpdateService is a constructor-injected dependency" check_AC7_controller_injects_service
run AC8  "Controller: upsertAll( is invoked from controller"                            check_AC8_controller_invokes_upsert_all
echo

# ── AC9: NEGATIVE — itemdataRepository.save gone from controller ─────────────
#
# All saves must have moved into SkuBatchCreateUpdateService. Any remaining
# itemdataRepository.save( in the controller body is a regression that
# reintroduces the per-row autocommit anti-pattern.

check_AC9_no_itemdata_save_in_controller() {
    ! grep -qE "itemdataRepository\.save\s*\(" "$CONTROLLER"
}

run AC9  "Controller NEG: itemdataRepository.save( gone from controller (all saves in service)" \
         check_AC9_no_itemdata_save_in_controller
echo

# ── AC10: NEGATIVE — self-recursion deleted ──────────────────────────────────
#
# update() must no longer call create() on this (self-invocation). The proxy
# is not intercepted on self-calls, so even a @Transactional on create() would
# silently not fire if called this way. The fix deletes the self-call entirely.

check_AC10_no_self_recursion() {
    # grep for this.create( or bare invocation of create( inside the update method body
    ! grep -qE "this\.create\s*\(" "$CONTROLLER"
}

run AC10 "Controller NEG: this.create( self-recursion deleted from update()" \
         check_AC10_no_self_recursion
echo

# ── AC11: NEGATIVE — line 275 Optional.get() NPE deleted ────────────────────
#
# The debug log at former line 275 called itemDataValue.get() on an
# Optional.empty() on the new-SKU update path, throwing NoSuchElementException.
# The new service does not contain this log statement.

check_AC11_no_optional_get_in_controller() {
    ! grep -qE "itemDataValue\.get\s*\(\)" "$CONTROLLER"
}

run AC11 "Controller NEG: itemDataValue.get() (line 275 NPE) deleted from controller" \
         check_AC11_no_optional_get_in_controller
echo

# ── AC12: POSITIVE — create() and update() return 422 on validation failure ──
#
# Ticket AC3 requires UNPROCESSABLE_ENTITY (422) for /update and /create
# validation failures. /delete must stay at BAD_REQUEST (400).

check_AC12_controller_returns_422_on_failure() {
    grep -qE "UNPROCESSABLE_ENTITY" "$CONTROLLER"
}

run AC12 "Controller: HttpStatus.UNPROCESSABLE_ENTITY present for create/update failures (422)" \
         check_AC12_controller_returns_422_on_failure
echo

# ── AC13: POSITIVE — /delete still returns 400 ───────────────────────────────

check_AC13_delete_still_returns_400() {
    grep -qE "ResponseEntity\.badRequest\(\)|BAD_REQUEST" "$CONTROLLER"
}

run AC13 "Controller: HttpStatus.BAD_REQUEST still present (delete unchanged at 400)" \
         check_AC13_delete_still_returns_400
echo

# ── AC14: POSITIVE — failure message log in controller catch ────────────────

check_AC14_failure_log_in_controller_catch() {
    grep -qE "catch\s*\(\s*WebserviceBusinessExceptionClientSide" "$CONTROLLER" && \
    grep -qE "MessageStatus\.FAILED" "$CONTROLLER"
}
check_AC14_failure_log_not_in_service() {
    ! grep -qE "MessageStatus\.FAILED" "$SERVICE"
}

run AC14a "Controller: failure log MessageStatus.FAILED in controller catch block" \
          check_AC14_failure_log_in_controller_catch
run AC14b "Service NEG: MessageStatus.FAILED NOT inside SkuBatchCreateUpdateService" \
          check_AC14_failure_log_not_in_service
echo

# ── AC15: POSITIVE — @CacheEvict on both create() and update() ──────────────
#
# Pre-resolved decision #6: @CacheEvict(value="itemdata", allEntries=true)
# must remain on both controller entry points.

check_AC15_cache_evict_present() {
    local count
    count=$(grep -cE '@CacheEvict\s*\(.*value.*=.*"itemdata"' "$CONTROLLER" || true)
    [ "$count" -ge 2 ]
}

run AC15 "Controller: @CacheEvict(value=\"itemdata\") present on >= 2 methods (create + update)" \
         check_AC15_cache_evict_present
echo

# ── AC16-AC17: Tests exist ───────────────────────────────────────────────────

check_AC16_service_test_exists() {
    [ -f "$SERVICE_TEST" ]
}
check_AC17_controller_test_exists() {
    [ -f "$CONTROLLER_TEST" ]
}
check_AC17b_it_test_exists() {
    [ -f "$IT_TEST" ]
}

run AC16  "Test: SkuBatchCreateUpdateServiceUnitTest.java exists"         check_AC16_service_test_exists
run AC17a "Test: SkuRestControllerUnitTest.java exists"                   check_AC17_controller_test_exists
run AC17b "Test: SkuRestControllerAtomicityIntegrationTest.java exists"   check_AC17b_it_test_exists
echo

# ── AC18-AC20: Targeted tests pass ──────────────────────────────────────────

run AC18 "Unit tests pass (SkuBatchCreateUpdateServiceUnitTest)" \
    "$MVN" test -Dtest=SkuBatchCreateUpdateServiceUnitTest -DfailIfNoTests=false -q
run AC19 "Unit tests pass (SkuRestControllerUnitTest)" \
    "$MVN" test -Dtest=SkuRestControllerUnitTest -DfailIfNoTests=false -q
run AC20 "Integration test passes (SkuRestControllerAtomicityIntegrationTest)" \
    "$MVN" test -Dtest=SkuRestControllerAtomicityIntegrationTest -DfailIfNoTests=false -q
echo

# ── AC21: No regression on existing /rest/** handler tests ──────────────────

run AC21 "Regression: RestExceptionHandlerUnitTest still passes (SBDEV-2230 contract)" \
    "$MVN" test -Dtest=RestExceptionHandlerUnitTest -DfailIfNoTests=false -q
echo

# ── AC22: NEGATIVE — no messageService.create* call inside service ───────────
#
# MessageService.createMessage internally self-invokes createServiceLog on the
# same bean, so @Transactional(REQUIRES_NEW) does NOT fire (see plan §3.4).
# If a messageService.create* call were placed inside upsertAll, the log would
# silently roll back with the data on any failure — corrupting the audit log.

check_AC22_no_message_log_in_service() {
    ! grep -qE "messageService\.(create|log|save)" "$SERVICE"
}

run AC22 "Service NEG: no messageService.create* call inside SkuBatchCreateUpdateService (REQUIRES_NEW pitfall)" \
         check_AC22_no_message_log_in_service
echo

echo "Result: $PASS pass, $FAIL fail"
echo
[ "$FAIL" -eq 0 ]
