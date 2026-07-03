#!/usr/bin/env bash
# verify-260629-transfers-available-lanes-orderbatchid-mislabel.sh
# Machine-checkable acceptance for:
#   "Transfers availableTransferLanes — orderBatchId mislabeled as customerOrderID"
#   Plan: sbdocs/1-Projects/wms2/plan/260629-transfers-available-lanes-orderbatchid-mislabel.md
#
# Run after each implementation pass; paste output into the end-of-task report:
#   PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
#     bash sbdocs/9-System/scripts/verify-260629-transfers-available-lanes-orderbatchid-mislabel.sh
#
# Exit 0 iff all checks pass.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1; local desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}
skip() {
    local id=$1; local desc=$2; local reason=$3
    printf "  SKIP  %-10s  %s  (%s)\n" "$id" "$desc" "$reason"; SKIP=$((SKIP+1))
}

file_contains()     { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }

mvn_test_passes() {
    local test_class=$1
    # Rely on mvn's exit code: Surefire fails the build on any test failure.
    # (Do NOT grep stdout for "BUILD SUCCESS"/"Tests run" — `-q` suppresses those [INFO] lines.)
    mvn test -Dtest="$test_class" -DfailIfNoTests=false -q >/dev/null 2>&1
}

CTRL="src/main/java/net/aim_ai/wms/controller/TransfersController.java"

# --- A: getAvailableTransferLanes resolves the real customerorder id ----------

# A1 (POSITIVE): the controller resolves a Customerorder from the batch id.
#     Scoped to the availableTransferLanes handler body via a windowed grep.
check_A1_resolves_co_from_batch() {
    # Look within ~15 lines after the availableTransferLanes mapping for the resolve call.
    awk '/availableTransferLanes/{f=1} f{print} /^    \}/{if(f)f=0}' "$CTRL" \
        | grep -qE 'findByOrderbatchId\s*\(\s*orderBatchId\s*\)'
}

# A2 (POSITIVE): the service is called with the resolved CO id, not the raw batch id.
check_A2_passes_co_id() {
    awk '/availableTransferLanes/{f=1} f{print} /^    \}/{if(f)f=0}' "$CTRL" \
        | grep -qE 'transferOrderService\.getAvailableTransferLanes\s*\(\s*customerOrder\.getId\(\)\s*\)'
}

# A3 (NEGATIVE): the old straight-through call (batch id passed as customerOrderID) is gone.
check_A3_straight_through_gone() {
    awk '/availableTransferLanes/{f=1} f{print} /^    \}/{if(f)f=0}' "$CTRL" \
        | grep -qE 'transferOrderService\.getAvailableTransferLanes\s*\(\s*orderBatchId\s*\)' \
        && return 1 || return 0
}

# A5 (POSITIVE): empty-batch guard present — returns an empty list instead of 500 on .get(0).
check_A5_empty_batch_guard() {
    awk '/availableTransferLanes/{f=1} f{print} /^    \}/{if(f)f=0}' "$CTRL" \
        | grep -qE 'orders\.isEmpty\(\)' \
        && awk '/availableTransferLanes/{f=1} f{print} /^    \}/{if(f)f=0}' "$CTRL" \
             | grep -qE 'Collections\.emptyList\(\)'
}

# A4 (SANITY): the endpoint mapping still exists.
check_A4_endpoint_present() {
    file_contains 'value\s*=\s*"/availableTransferLanes"' "$CTRL"
}

echo
echo "verify-260629-transfers-available-lanes-orderbatchid-mislabel — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

run A4 "endpoint /availableTransferLanes mapping present"            check_A4_endpoint_present
run A1 "controller resolves CO via findByOrderbatchId(orderBatchId)" check_A1_resolves_co_from_batch
run A2 "service called with customerOrder.getId() (real CO id)"      check_A2_passes_co_id
run A3 "old straight-through getAvailableTransferLanes(orderBatchId) removed" check_A3_straight_through_gone
run A5 "empty-batch guard present (orders.isEmpty() → Collections.emptyList())" check_A5_empty_batch_guard

echo

# --- Targeted JUnit (proves it works, not just that the call exists) ----------
if [ -f src/test/java/net/aim_ai/wms/unit/controller/TransfersControllerUnitTest.java ] \
   || grep -rql "class TransfersControllerUnitTest" src/test 2>/dev/null; then
    run A-test "TransfersControllerUnitTest passes" mvn_test_passes TransfersControllerUnitTest
else
    skip A-test "TransfersControllerUnitTest" "test class not present yet (add per plan §8)"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
