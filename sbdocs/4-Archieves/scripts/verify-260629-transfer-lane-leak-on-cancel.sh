#!/usr/bin/env bash
# verify-260629-transfer-lane-leak-on-cancel.sh
#
# Machine-checkable acceptance for `260629-transfer-lane-leak-on-cancel.md`.
#
# Fixes:
#   A     CustomerorderService.cancelOrder      — direct guarded setTransferlaneId(null)
#   B     CustomerorderService.forceCancelOrder — direct guarded setTransferlaneId(null)
#   C1/D  TransferOrderService.unlinkTransferLaneFromTransferOrder
#                                                — add @Transactional(tenantTransactionManager)
#
# NEGATIVE invariant: the cancel paths must NOT call unlinkTransferLaneFromTransferOrder
# (that resets state to 505 — un-cancels — and has no TM).
#
# Run after every implementation pass (from anywhere):
#   $ bash sbdocs/9-System/scripts/verify-260629-transfer-lane-leak-on-cancel.sh
#   $ PROJECT_ROOT=/path/to/v2/wms2-api bash .../verify-260629-...sh   # override root

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1))
}

file_contains()     { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { ! grep -qE "$1" "$2" 2>/dev/null; }
# Multi-line variant — perl -0777 so a regex can span newlines.
file_contains_ml()  { PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null; }

# Extract a single method body by name (brace-balanced) to a temp file.
# Lets us scope greps to one method without depending on exact line numbers.
method_body() {
    local file=$1 method=$2 out=$3
    awk -v m="$method" '
        index($0, m"(") && !started { started=1 }
        started {
            print
            n += gsub(/{/, "{")
            n -= gsub(/}/, "}")
            if (n > 0) seen=1
            if (seen && n <= 0) exit
        }
    ' "$file" > "$out"
}

SVC=src/main/java/net/aim_ai/wms/service
CO_SVC=$SVC/CustomerorderService.java
TO_SVC=$SVC/TransferOrderService.java

echo
echo "verify-260629-transfer-lane-leak-on-cancel — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# --- Prereq: target files present --------------------------------------------
run PRE-1 "Prereq — CustomerorderService.java present" test -f "$CO_SVC"
run PRE-2 "Prereq — TransferOrderService.java present" test -f "$TO_SVC"

echo

# --- Fix A — cancelOrder clears transfer lane --------------------------------
TMP_CANCEL="$(mktemp)"; method_body "$CO_SVC" "public void cancelOrder" "$TMP_CANCEL"

run Aa "A — cancelOrder body contains guarded setTransferlaneId(null)" \
    file_contains_ml 'getTransferlaneId\(\)\s*!=\s*null[^}]*setTransferlaneId\(null\)' "$TMP_CANCEL"
run Ab "A — cancelOrder does NOT call unlinkTransferLaneFromTransferOrder (no un-cancel)" \
    file_not_contains 'unlinkTransferLaneFromTransferOrder' "$TMP_CANCEL"

echo

# --- Fix B — forceCancelOrder clears transfer lane ---------------------------
TMP_FORCE="$(mktemp)"; method_body "$CO_SVC" "void forceCancelOrder" "$TMP_FORCE"

run Ba "B — forceCancelOrder body contains guarded setTransferlaneId(null)" \
    file_contains_ml 'getTransferlaneId\(\)\s*!=\s*null[^}]*setTransferlaneId\(null\)' "$TMP_FORCE"
run Bb "B — forceCancelOrder does NOT call unlinkTransferLaneFromTransferOrder" \
    file_not_contains 'unlinkTransferLaneFromTransferOrder' "$TMP_FORCE"

echo

# --- Fix C1/D — unlinkTransferLaneFromTransferOrder gets the tenant TM --------
run Da "D — @Transactional(tenantTransactionManager) immediately precedes unlinkTransferLaneFromTransferOrder" \
    file_contains_ml '@Transactional\(\s*value\s*=\s*"tenantTransactionManager"[^)]*\)\s*\n\s*public\s+void\s+unlinkTransferLaneFromTransferOrder\(' "$TO_SVC"
run Db "D — that @Transactional declares rollbackFor BusinessException + FacadeException" \
    file_contains_ml '@Transactional\(\s*value\s*=\s*"tenantTransactionManager",\s*rollbackFor\s*=\s*\{BusinessException\.class,\s*FacadeException\.class\}\)\s*\n\s*public\s+void\s+unlinkTransferLaneFromTransferOrder\(' "$TO_SVC"
run Dc "D — method body still clears the lane (setTransferlaneId(null))" \
    file_contains 'customerOrder\.setTransferlaneId\(null\)' "$TO_SVC"

rm -f "$TMP_CANCEL" "$TMP_FORCE"

echo

# --- Optional: targeted unit tests -------------------------------------------
mvn_test_passes() {
    local cls=$1
    mvn test -Dtest="$cls" -DfailIfNoTests=false >/dev/null 2>&1
}

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T-CO "T — CustomerorderServiceUnitTest passes" mvn_test_passes CustomerorderServiceUnitTest
    run T-TO "T — TransferOrderServiceUnitTest passes"  mvn_test_passes TransferOrderServiceUnitTest
    # Full-chain no-double-flush property (Architect rec #1 / Critic high-value):
    # cancelOrder -> finalizeBatchIfComplete clears the lane and flushes @Version exactly once.
    run T-CHAIN "T — cancelOrder_singleOrderTransferBatch_clearsLaneAndFinalizesOnce passes" \
        mvn_test_passes 'CustomerorderServiceUnitTest#cancelOrder_singleOrderTransferBatch_clearsLaneAndFinalizesOnce'
else
    skip T-mvn "Targeted unit-test runs" "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
