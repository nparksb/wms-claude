#!/usr/bin/env bash
# verify-260504-transfer-order-null-transferlane-crash.sh
#
# Machine-checkable acceptance for plan:
#   sbdocs/1-Projects/wms1/plan/260504-transfer-order-null-transferlane-crash.md
#
# Run from anywhere; PROJECT_ROOT defaults to v1/wms-api on Nam's box.
# Usage:
#   bash sbdocs/9-System/scripts/verify-260504-transfer-order-null-transferlane-crash.sh
#   PROJECT_ROOT=/path/to/v1/wms-api bash .../verify-...sh

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v1/wms-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

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

# --- assertion helpers ---
file_contains()      { grep -qE "$1" "$2"; }
file_not_contains()  { ! grep -qE "$1" "$2"; }
file_contains_ml()   {
    [ -f "$2" ] || return 1 local p=$1; perl -0777 -e 'my $p=shift; my $f=do{local $/;<STDIN>}; exit($f=~/$p/s ? 0 : 1)' "$p" < "$2"; }  # multi-line via Perl slurp

mvn_test_passes() {
    local test_class=$1
    mvn test -Dtest="$test_class" -DfailIfNoTests=false 2>&1 \
        | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0"
}

# --- file paths (relative to PROJECT_ROOT) ---
TOS=src/main/java/net/aim_ai/wms/service/TransferOrderService.java
MTOS=src/main/java/net/aim_ai/wms/service/mobile/MobileTransferOrderService.java
TOC=src/main/java/net/aim_ai/wms/controller/mobile/TransferOrderController.java
TOS_TEST=src/test/java/net/aim_ai/wms/unit/service/TransferOrderServiceUnitTest.java
TOS_IT=src/test/java/net/aim_ai/wms/service/TransferOrderServiceIT.java
MTOS_TEST=src/test/java/net/aim_ai/wms/unit/service/mobile/MobileTransferOrderServiceUnitTest.java
FLYWAY_DIR=src/main/resources/db/migration

# Primary Flyway slot is V1.1.06 per plan; allow V1.1.07 as fallback if slot was already taken.
FLYWAY_FILE=""
for cand in "$FLYWAY_DIR/V1.1.06__transfer_order_state_fix.sql" \
            "$FLYWAY_DIR/V1.1.07__transfer_order_state_fix.sql"; do
    if [ -f "$cand" ]; then FLYWAY_FILE="$cand"; break; fi
done

# === Per-rollout-item check functions =========================================

# Fix A — unlinkTransferLaneFromTransferOrder resets state
check_A1_state_reset_in_unlink() {
    # Match the unlink method body containing setTransferlaneId(null) and setState(CUSTOMER_ORDER_ACTIVATED)
    # within a window that also names the method, to avoid matching unrelated places.
    file_contains_ml \
'public void unlinkTransferLaneFromTransferOrder\([^)]*\).*setTransferlaneId\(null\).*setState\(CUSTOMER_ORDER_ACTIVATED\)' \
        "$TOS"
}

# Fix B — updateOrderList has null-transferlaneId skip
check_B1_updateOrderList_null_skip() {
    file_contains_ml \
'public .+ updateOrderList\(\).*?customerOrder\.getTransferlaneId\(\) == null.*?continue;' \
        "$MTOS"
}

# Fix B — updateOrder has null-transferlaneId early return
check_B2_updateOrder_null_return() {
    file_contains_ml \
'public TransferOrderDto updateOrder\(TransferOrderDto.*customerOrder\.getTransferlaneId\(\) == null.*return transferOrderDto;' \
        "$MTOS"
}

# Fix C — updateOrderPosition throws BusinessException for null transferlaneId
check_C1_updateOrderPosition_throws() {
    file_contains_ml \
'public TransferOrderPositionDto updateOrderPosition\(TransferOrderPositionDto.*customerOrder\.getTransferlaneId\(\) == null.*throw new BusinessException' \
        "$MTOS"
}

check_C1_throws_clause() {
    # The method signature now declares throws BusinessException
    file_contains \
'public TransferOrderPositionDto updateOrderPosition\([^)]*\) +throws BusinessException' \
        "$MTOS"
}

# Fix C (controller side) — processOrderPositionSelect wraps in catch (BusinessException)
check_C2_controller_catches_business_exception() {
    file_contains_ml \
'processOrderPositionSelect.*catch\s*\(\s*BusinessException' \
        "$TOC"
}

# Fix D — dead method assignTransferLane(Customerorder) removed
check_D1_dead_method_gone() {
    # Old signature was: public void assignTransferLane(Customerorder customerOrder)
    file_not_contains \
'public void assignTransferLane\(Customerorder customerOrder\)' \
        "$TOS"
}

# Fix E — Flyway data fix file exists with canonical UPDATE
check_E1_flyway_file_exists() {
    [ -n "$FLYWAY_FILE" ] && [ -f "$FLYWAY_FILE" ]
}

check_E2_flyway_update_predicate() {
    [ -n "$FLYWAY_FILE" ] || return 1
    # Must update state=505 WHERE state=510 AND transferlane_id IS NULL.
    file_contains_ml \
'UPDATE\s+customerorder.*SET\s+state\s*=\s*505.*WHERE\s+state\s*=\s*510.*transferlane_id\s+IS\s+NULL' \
        "$FLYWAY_FILE"
}

check_E3_flyway_raise_notice_audit() {
    [ -n "$FLYWAY_FILE" ] || return 1
    # Must contain a RAISE NOTICE audit block.
    file_contains 'RAISE NOTICE' "$FLYWAY_FILE"
}

# Fix F1 — unit test asserts state after unlink
check_F1_unit_test_asserts_state() {
    # The (renamed) test calls unlinkTransferLaneFromTransferOrder and then asserts on getState()
    file_contains_ml \
'unlinkTransferLaneFromTransferOrder\(.+?\);.*assertThat\(.+?getState\(\)\).*CUSTOMER_ORDER_ACTIVATED' \
        "$TOS_TEST"
}

# Fix F1 — old test name removed (the original assertion-only test)
check_F1_old_name_gone() {
    file_not_contains \
'void unlinkTransferLaneFromTransferOrder_setsTransferlaneIdToNull\(\)' \
        "$TOS_TEST"
}

# Fix F1c — new test name present
check_F1c_new_name_present() {
    file_contains \
'void unlinkTransferLaneFromTransferOrder_clearsLaneAndResetsStateToActivated' \
        "$TOS_TEST"
}

# Fix F2 — integration test asserts state after unlink
check_F2_it_asserts_state() {
    file_contains_ml \
'unlinkTransferLaneFromTransferOrder\(.+?\);.*assertThat\(.+?getState\(\)\).*CUSTOMER_ORDER_ACTIVATED' \
        "$TOS_IT"
}

# Fix F3 — dead-method test removed
check_F3_dead_method_test_gone() {
    file_not_contains \
'void assignTransferLane_setsStateAndSaves\(\)' \
        "$TOS_TEST"
}

# Fix F4 — mobile test exercises the null-transferlaneId path in updateOrderList
check_F4_mobile_test_null_skip() {
    file_contains \
'updateOrderList_skipsOrderWithNullTransferlaneId' \
        "$MTOS_TEST"
}

# Fix F5 — mobile test exercises the BusinessException in updateOrderPosition
check_F5_mobile_test_business_exception() {
    file_contains \
'updateOrderPosition_withNullTransferlaneId_throwsBusinessException' \
        "$MTOS_TEST"
}

# === Wire into the runner =====================================================

echo
echo "verify-260504-transfer-order-null-transferlane-crash — running acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  Flyway file resolved to: ${FLYWAY_FILE:-<none>}"
echo

# Fix A — root cause
run A1   "Fix A — unlinkTransferLaneFromTransferOrder calls setState(CUSTOMER_ORDER_ACTIVATED)"  check_A1_state_reset_in_unlink

# Fix B — defensive guards in mobile reads
run B1   "Fix B — updateOrderList skips orders with null transferlaneId"                          check_B1_updateOrderList_null_skip
run B2   "Fix B — updateOrder early-returns for null transferlaneId"                              check_B2_updateOrder_null_return

# Fix C — guard in updateOrderPosition + controller catch
run C1a  "Fix C — updateOrderPosition throws BusinessException for null transferlaneId"            check_C1_updateOrderPosition_throws
run C1b  "Fix C — updateOrderPosition declares throws BusinessException"                            check_C1_throws_clause
run C2   "Fix C (ctrl) — processOrderPositionSelect catches BusinessException"                     check_C2_controller_catches_business_exception

# Fix D — dead method removal
run D1   "Fix D — assignTransferLane(Customerorder) dead method removed"                          check_D1_dead_method_gone

# Fix E — Flyway data fix
run E1   "Fix E — Flyway migration file exists (V1.1.06 primary; V1.1.07 fallback)"               check_E1_flyway_file_exists
run E2   "Fix E — Flyway UPDATE matches state=505 WHERE state=510 AND transferlane_id IS NULL"     check_E2_flyway_update_predicate
run E3   "Fix E — Flyway migration contains RAISE NOTICE audit block"                             check_E3_flyway_raise_notice_audit

# Fix F — tests
run F1a  "Fix F1 — unit test asserts state after unlink"                                          check_F1_unit_test_asserts_state
run F1b  "Fix F1 — old test name removed (renamed)"                                               check_F1_old_name_gone
run F1c  "Fix F1 — new test name present"                                                         check_F1c_new_name_present
run F2   "Fix F2 — integration test asserts state after unlink"                                    check_F2_it_asserts_state
run F3   "Fix F3 — dead-method test removed"                                                       check_F3_dead_method_test_gone
run F4   "Fix F4 — mobile unit test exercises null-id skip in updateOrderList"                     check_F4_mobile_test_null_skip
run F5   "Fix F5 — mobile unit test exercises BusinessException in updateOrderPosition"           check_F5_mobile_test_business_exception

# Behavioral check — targeted JUnit run (only when explicitly requested via env var to keep this script fast)
if [ "${RUN_MVN:-0}" = "1" ]; then
    run TEST1 "TransferOrderServiceUnitTest passes (mvn)"        mvn_test_passes TransferOrderServiceUnitTest
    run TEST2 "MobileTransferOrderServiceUnitTest passes (mvn)"  mvn_test_passes MobileTransferOrderServiceUnitTest
else
    skip TEST1 "TransferOrderServiceUnitTest passes (mvn)"        "set RUN_MVN=1 to run"
    skip TEST2 "MobileTransferOrderServiceUnitTest passes (mvn)"  "set RUN_MVN=1 to run"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
