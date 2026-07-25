#!/usr/bin/env bash
# verify-260629-activate-transfer-atomicity.sh
# Machine-checkable acceptance for plan 260629-activate-transfer-atomicity.
#
#   $ PROJECT_ROOT=/path/to/v2/wms2-api bash sbdocs/9-System/scripts/verify-260629-activate-transfer-atomicity.sh
#
# Exit 0 if all checks pass, non-zero otherwise.
#
# Defect: TransfersController.activateTransferOrder calls TWO separately-@Transactional
# service methods (activateTransferOrder + assignTransferLaneToTransferOrder) in sequence,
# in a non-transactional controller -> two TXs -> order can commit at state 505-with-lane.
# Fix: ONE @Transactional("tenantTransactionManager") orchestration method
# TransferOrderService.activateAndAssignTransferLane(...) that lands state 510 + lane in a
# single tx; the controller calls only that.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

SVC="src/main/java/net/aim_ai/wms/service/TransferOrderService.java"
CTRL="src/main/java/net/aim_ai/wms/controller/TransfersController.java"

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
    printf "  SKIP  %-10s  %s  (%s)\n" "$id" "$desc" "$reason"; SKIP=$((SKIP+1))
}

file_contains() { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }

# Extract the body of TransfersController.activateTransferOrder (from its method
# declaration line down to the assignTransferLane method that follows it) so the
# negative checks are scoped to that ONE method, not the whole controller file
# (which still legitimately calls assignTransferLaneToTransferOrder from
# reassignTransferLane and assignTransferLane).
activate_method_body() {
    awk '/public ResponseEntity<Object> activateTransferOrder\(/{f=1}
         f{print}
         f && /public ResponseEntity<Object> assignTransferLane\(/{exit}' "$CTRL"
}

# Extract the body of the new orchestration method for self-invocation checks.
# CAVEAT: this stops at the FIRST 4-space-indented `}` (the method close for the
# canonical §5.1 body, whose only inner block — the lock-loss `if` — closes at 8
# spaces). If the implementer formats an inner block to close at 4-space indent,
# extraction truncates early and the P4/P5/N3 counts below could mis-evaluate.
# Keep inner blocks indented >4 spaces (the specified body already does).
orchestration_method_body() {
    awk '/public void activateAndAssignTransferLane\(/{f=1}
         f{print}
         f && /^    }/{print; exit}' "$SVC"
}

# === POSITIVE checks =========================================================

check_P1_orchestration_method_exists() {
    file_contains 'public void activateAndAssignTransferLane\(Location .*Customerorder .*\) throws BusinessException' "$SVC"
}

check_P2_orchestration_tenant_tm() {
    # The @Transactional immediately preceding the new method must use tenantTransactionManager + rollbackFor.
    orchestration_lines=$(grep -n 'public void activateAndAssignTransferLane(' "$SVC" | head -1 | cut -d: -f1)
    [ -n "$orchestration_lines" ] || return 1
    start=$((orchestration_lines-2))
    [ "$start" -lt 1 ] && start=1
    sed -n "${start},${orchestration_lines}p" "$SVC" \
        | grep -qE '@Transactional\(value = "tenantTransactionManager", rollbackFor = \{BusinessException\.class, FacadeException\.class\}\)'
}

check_P3_orchestration_sets_state_510() {
    orchestration_method_body | grep -qE 'setState\(CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED\)'
}

check_P4_orchestration_single_save() {
    local n
    n=$(orchestration_method_body | grep -cE 'customerorderRepository\.save\(')
    [ "$n" -eq 1 ]
}

check_P5_orchestration_one_lock_check() {
    local n
    n=$(orchestration_method_body | grep -cE 'getAvailableTransferLanesForUpdate\(')
    [ "$n" -eq 1 ]
}

check_P6_controller_calls_orchestration() {
    activate_method_body | grep -qE 'transferOrderService\.activateAndAssignTransferLane\('
}

check_P7_legacy_assign_kept() {
    file_contains 'public void assignTransferLaneToTransferOrder\(Location .*Customerorder ' "$SVC"
}

check_P8_legacy_activate_kept() {
    file_contains 'public void activateTransferOrder\(Location .*Customerorder ' "$SVC"
}

check_P9_other_assign_callers_intact() {
    # reassignTransferLane + assignTransferLane still call assignTransferLaneToTransferOrder.
    local n
    n=$(grep -cE 'transferOrderService\.assignTransferLaneToTransferOrder\(' "$CTRL")
    [ "$n" -ge 2 ]
}

# === NEGATIVE checks =========================================================

check_N1_controller_no_split_activate_call() {
    # The activateTransferOrder controller method must NOT call the legacy
    # transferOrderService.activateTransferOrder(...) anymore.
    ! activate_method_body | grep -qE 'transferOrderService\.activateTransferOrder\('
}

check_N2_controller_no_split_assign_call() {
    # ...and must NOT call assignTransferLaneToTransferOrder(...) (that call moved
    # into the single orchestration method).
    ! activate_method_body | grep -qE 'transferOrderService\.assignTransferLaneToTransferOrder\('
}

check_N3_orchestration_no_self_invocation() {
    # The new method must not self-invoke the legacy @Transactional siblings on `this`
    # (CGLIB-bypass trap) — Option 1 inlines the writes instead.
    ! orchestration_method_body | grep -qE 'this\.(activateTransferOrder|assignTransferLaneToTransferOrder)\(|(^|[^.])activateTransferOrder\(|assignTransferLaneToTransferOrder\('
}

# === Wire into the runner ====================================================

echo
echo "verify-260629-activate-transfer-atomicity — running acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

run P1  "new activateAndAssignTransferLane method exists"        check_P1_orchestration_method_exists
run P2  "orchestration method uses tenantTransactionManager+rollbackFor" check_P2_orchestration_tenant_tm
run P3  "orchestration sets state CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED(510)" check_P3_orchestration_sets_state_510
run P4  "orchestration calls save() exactly once"                check_P4_orchestration_single_save
run P5  "orchestration does ONE availability lock check"         check_P5_orchestration_one_lock_check
run P6  "controller activateTransferOrder delegates to orchestration" check_P6_controller_calls_orchestration
run P7  "legacy assignTransferLaneToTransferOrder kept"          check_P7_legacy_assign_kept
run P8  "legacy activateTransferOrder kept"                      check_P8_legacy_activate_kept
run P9  "other assign callers (reassign/assign) intact"          check_P9_other_assign_callers_intact
echo
run N1  "controller no longer calls legacy activateTransferOrder" check_N1_controller_no_split_activate_call
run N2  "controller no longer calls assign separately"           check_N2_controller_no_split_assign_call
run N3  "orchestration does not self-invoke @Transactional siblings" check_N3_orchestration_no_self_invocation
echo

# === Optional: targeted JUnit tests (code-shape grep proves the call exists,
# the tests prove it works). Gate with SKIP_MVN=1 to skip in fast runs. ========
if [ "${SKIP_MVN:-1}" = "0" ]; then
    mvn_test_passes() {
        # Rely on mvn's exit code: Surefire fails the build on any test failure.
        # (Do NOT grep stdout for "BUILD SUCCESS"/"Tests run" — `-q` suppresses those [INFO] lines.)
        mvn test -Dtest="$1" -DfailIfNoTests=false -q >/dev/null 2>&1
    }
    run T1 "TransferOrderServiceUnitTest passes"  mvn_test_passes TransferOrderServiceUnitTest
    run T2 "TransfersControllerUnitTest passes"   mvn_test_passes TransfersControllerUnitTest
else
    skip T1 "TransferOrderServiceUnitTest"  "SKIP_MVN!=0"
    skip T2 "TransfersControllerUnitTest"   "SKIP_MVN!=0"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
