#!/usr/bin/env bash
# verify-SBDEV-2231-order-rest-create-partial-batch-atomicity.sh
#
# Acceptance checks for SBDEV-2231: OrderRestController.create partial-batch
# atomicity. Validates that the save loop has been extracted into a new
# @Transactional OrderBatchCreationService, that the controller no longer
# auto-commits individual repository.save() calls, and that the failure
# message log lives in the controller catch (outside the rolled-back tx).
#
# Run from the v2/wms2-api project root (default) or override PROJECT_ROOT:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2231-order-rest-create-partial-batch-atomicity.sh
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

SERVICE="src/main/java/net/aim_ai/wms/service/OrderBatchCreationService.java"
CONTROLLER="src/main/java/net/aim_ai/wms/controller/rest/OrderRestController.java"
SERVICE_TEST="src/test/java/net/aim_ai/wms/unit/service/OrderBatchCreationServiceUnitTest.java"
CONTROLLER_TEST="src/test/java/net/aim_ai/wms/unit/controller/rest/OrderRestControllerUnitTest.java"

echo
echo "verify-SBDEV-2231 — OrderRestController.create partial-batch atomicity"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# ── AC1-AC5: OrderBatchCreationService presence & shape ─────────────────────

check_AC1_service_exists() {
    [ -f "$SERVICE" ]
}
check_AC2_service_annotated() {
    grep -qE "^@Service\b" "$SERVICE"
}
check_AC3_transactional_with_tenant_manager() {
    # Either single-line or multi-line @Transactional; require value = "tenantTransactionManager"
    grep -Pzo "(?s)@Transactional\s*\([^)]*value\s*=\s*\"tenantTransactionManager\"" "$SERVICE" >/dev/null
}
check_AC4_rollback_for_wsbce() {
    grep -Pzo "(?s)@Transactional\s*\([^)]*rollbackFor\s*=[^)]*WebserviceBusinessExceptionClientSide\.class" "$SERVICE" >/dev/null
}
check_AC4b_rollback_for_business_exception() {
    # BusinessException (checked) is thrown by basicService.generateNumber() on SequenceExhausted.
    # Without this, a sequence-exhaustion failure would COMMIT prior saves.
    grep -Pzo "(?s)@Transactional\s*\([^)]*rollbackFor\s*=[^)]*BusinessException\.class" "$SERVICE" >/dev/null
}
check_AC5_constructor_injection_no_autowired_field() {
    # No `@Autowired` directly above a field declaration (allow on constructors per pre-Spring-4.3 style if present)
    # Heuristic: ensure no `@Autowired\n    private ` pattern
    ! grep -Pzo "(?s)@Autowired\s*\n\s*private\s+\w" "$SERVICE" >/dev/null
}

run AC1 "Service: OrderBatchCreationService.java exists"                check_AC1_service_exists
run AC2 "Service: annotated @Service"                                   check_AC2_service_annotated
run AC3 "Service: @Transactional(value = \"tenantTransactionManager\")" check_AC3_transactional_with_tenant_manager
run AC4  "Service: rollbackFor includes WebserviceBusinessExceptionClientSide.class" check_AC4_rollback_for_wsbce
run AC4b "Service: rollbackFor includes BusinessException.class (sequence exhaustion path)" check_AC4b_rollback_for_business_exception
run AC5 "Service: constructor injection (no @Autowired field)"          check_AC5_constructor_injection_no_autowired_field
echo

# ── AC6-AC7: OrderRestController wiring ─────────────────────────────────────

check_AC6_controller_injects_service() {
    # OrderBatchCreationService must appear as a field/constructor-parameter type
    grep -qE "OrderBatchCreationService\s+\w+" "$CONTROLLER"
}
check_AC7_controller_invokes_create_all() {
    grep -qE "orderBatchCreationService\.createAll\s*\(" "$CONTROLLER"
}

run AC6 "Controller: OrderBatchCreationService is a constructor-injected dependency" check_AC6_controller_injects_service
run AC7 "Controller: create() delegates to orderBatchCreationService.createAll("    check_AC7_controller_invokes_create_all
echo

# ── AC8-AC10: NEGATIVE — save loop fully extracted from controller ──────────
#
# The controller must no longer call repository.save() for batch / order /
# position entities. We grep the controller file (the only public `create`
# method in this controller is the one we restructured).

check_AC8_no_batch_save_in_controller() {
    ! grep -qE "customerorderBatchRepository\.save\s*\(" "$CONTROLLER"
}
check_AC9_no_order_save_in_controller() {
    # Scope to create() method only — finishedQA legitimately calls customerorderRepository.save
    # Extract from @PutMapping /create to the first private helper that follows it
    local create_body
    create_body=$(awk '/@PutMapping\(value = "\/create"/{flag=1} /^    private void resolveClient/{flag=0} flag' "$CONTROLLER")
    ! echo "$create_body" | grep -qE "customerorderRepository\.save\s*\("
}
check_AC10_no_position_save_in_controller() {
    ! grep -qE "customerorderPositionRepository\.save\s*\(" "$CONTROLLER"
}

run AC8  "Controller NEG: customerorderBatchRepository.save( gone from controller"    check_AC8_no_batch_save_in_controller
run AC9  "Controller NEG: customerorderRepository.save( gone from controller"         check_AC9_no_order_save_in_controller
run AC10 "Controller NEG: customerorderPositionRepository.save( gone from controller" check_AC10_no_position_save_in_controller
echo

# ── AC11: Failure message log lives in controller catch (outside tx) ────────
#
# The controller catch block on WebserviceBusinessExceptionClientSide must
# invoke MessageStatus.FAILED logging. Specifically: a catch block with that
# exception type must be present AND MessageStatus.FAILED must appear in the
# controller (since today's controller is where the FAILED log lived before
# this plan AND where we want it after).

check_AC11_failure_log_in_controller() {
    # POSITIVE: catch (WebserviceBusinessExceptionClientSide ...) present
    grep -qE "catch\s*\(\s*WebserviceBusinessExceptionClientSide" "$CONTROLLER" && \
    grep -qE "MessageStatus\.FAILED" "$CONTROLLER"
}
check_AC11_failure_log_not_in_service() {
    # NEGATIVE: failure message log must NOT live inside the service
    # (would be rolled back with the tx, defeating the audit log purpose)
    ! grep -qE "MessageStatus\.FAILED" "$SERVICE"
}

run AC11  "Controller: failure log MessageStatus.FAILED runs in controller catch" check_AC11_failure_log_in_controller
run AC11- "Service NEG: failure log MessageStatus.FAILED NOT inside service tx"   check_AC11_failure_log_not_in_service
echo

# ── AC12: Tests exist ───────────────────────────────────────────────────────

check_AC12_service_test_exists() {
    [ -f "$SERVICE_TEST" ]
}
check_AC12_controller_test_exists() {
    [ -f "$CONTROLLER_TEST" ]
}

run AC12a "Test: OrderBatchCreationServiceUnitTest.java exists" check_AC12_service_test_exists
run AC12b "Test: OrderRestControllerUnitTest.java exists"       check_AC12_controller_test_exists
echo

# ── AC13-AC14: Targeted unit tests pass ─────────────────────────────────────

run AC13 "Unit tests pass (OrderBatchCreationServiceUnitTest)" \
    "$MVN" test -Dtest=OrderBatchCreationServiceUnitTest -DfailIfNoTests=false -q
run AC14 "Unit tests pass (OrderRestControllerUnitTest)" \
    "$MVN" test -Dtest=OrderRestControllerUnitTest -DfailIfNoTests=false -q
echo

# ── AC15: No regression on RestEndpointExceptionHandler tests (SBDEV-2230) ─

run AC15 "Regression: RestExceptionHandlerUnitTest still passes (SBDEV-2230 contract)" \
    "$MVN" test -Dtest=RestExceptionHandlerUnitTest -DfailIfNoTests=false -q
echo

echo "Result: $PASS pass, $FAIL fail"
echo
[ "$FAIL" -eq 0 ]
