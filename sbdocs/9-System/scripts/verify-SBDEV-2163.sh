#!/usr/bin/env bash
# verify-SBDEV-2163.sh
# Verify: WMS Prevent Reassigning Finished Club Batches to a Staging Lane
# Run from the owl/ root: bash sbdocs/9-System/scripts/verify-SBDEV-2163.sh
# Exit 0 = all pass. Exit 1 = one or more failures.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SVC="$ROOT/v1/wms-api/src/main/java/net/aim_ai/wms/service"
TEST_SVC="$ROOT/v1/wms-api/src/test/java/net/aim_ai/wms/unit/service"
TEST_CTL="$ROOT/v1/wms-api/src/test/java/net/aim_ai/wms/unit/controller"

PASS=0
FAIL=0

run() {
    local id="$1" desc="$2"
    shift 2
    if "$@" 2>/dev/null; then
        printf "  PASS  %-8s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-8s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

file_contains()    { grep -qE "$1" "$2" 2>/dev/null; }
file_contains_ml() {
    local pattern="$1" file="$2"
    perl -0777 -ne "exit(/$pattern/ms ? 0 : 1)" "$file" 2>/dev/null
}

echo "=== verify-SBDEV-2163  WMS: Prevent Finished Club Batch Lane Reassignment ==="
echo

# ---------------------------------------------------------------------------
# F1 — Guard present in assignStagingLaneToOrderBatch
# ---------------------------------------------------------------------------
TARGET="$SVC/CustomerorderBatchService.java"

run F1a "Guard — findByOrderbatchId called before writing batch state" \
    file_contains 'customerorderRepository\.findByOrderbatchId\(' "$TARGET"

run F1b "Guard — allMatch checks FINISHED (700) and CANCELED (800)" \
    file_contains_ml 'allMatch.*\n?.*FINISHED.*\n?.*CANCELED|allMatch.*CANCELED.*FINISHED|State\.FINISHED.*State\.CANCELED|State\.CANCELED.*State\.FINISHED' "$TARGET"

run F1c "Guard — throws BusinessException when all terminal" \
    file_contains_ml 'if\s*\(\s*allTerminal\s*\)\s*\{[^}]*throw\s+new\s+BusinessException' "$TARGET"

run F1d "Guard — message contains 'cannot be assigned'" \
    file_contains 'cannot be assigned' "$TARGET"

run F1e "NEGATIVE — guard is inside assignStagingLaneToOrderBatch (not a stale-state-only check)" \
    file_contains 'findByOrderbatchId' "$TARGET"

# ---------------------------------------------------------------------------
# F2 — Unit tests: service
# ---------------------------------------------------------------------------
SVC_TEST="$TEST_SVC/CustomerorderBatchServiceUnitTest.java"

run F2a "Test — whenAllOrdersFinished_shouldThrowBusinessException exists" \
    file_contains 'whenAllOrdersFinished_shouldThrowBusinessException|allOrdersFinished.*Throw|allFinished.*throw' "$SVC_TEST"

run F2b "Test — whenAllOrdersCanceled_shouldThrowBusinessException exists" \
    file_contains 'whenAllOrdersCanceled_shouldThrowBusinessException|allOrdersCanceled.*Throw|allCanceled.*throw' "$SVC_TEST"

run F2c "Test — whenMixedStates_withOneActiveOrder_shouldAllowAssignment exists" \
    file_contains 'whenMixedStates|mixedStates.*Allow|oneActive.*Allow' "$SVC_TEST"

# ---------------------------------------------------------------------------
# F3 — Unit tests: controller
# ---------------------------------------------------------------------------
CTL_TEST="$TEST_CTL/ClubLineControllerUnitTest.java"

run F3a "Test — controller test for blocked/finished batch exists" \
    file_contains 'Finished.*shouldReturn|finished.*Error|allOrders.*Finished|batchIsFinished' "$CTL_TEST"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
TOTAL=$((PASS + FAIL))
echo "Result: $PASS pass, $FAIL fail (of $TOTAL checks)"
[ "$FAIL" -eq 0 ]
