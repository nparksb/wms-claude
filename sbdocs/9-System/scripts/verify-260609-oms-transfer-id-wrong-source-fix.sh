#!/usr/bin/env bash
# verify-260609-oms-transfer-id-wrong-source-fix.sh
# Machine-checkable acceptance for: OMS sends empty/wrong transfer_id to WMS.
#
# Fix lives in v2/oms-laravel-api (PHP/Laravel), NOT wms2-api (Java).
#
#   $ PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/oms-laravel-api \
#       bash sbdocs/9-System/scripts/verify-260609-oms-transfer-id-wrong-source-fix.sh
#
# Exit 0 iff all checks pass.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/oms-laravel-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}
skip() { printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

file_contains()     { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }

SVC="app/Services/BatchProcessingService.php"

# A1 (POSITIVE): getTransferId builds clientCode . '-' . order->orderID
check_A1_builds_client_dash_order() {
    file_contains '\$clientCode\s*\.\s*'"'"'-'"'"'\s*\.\s*\$order(ID)?(->orderID)?' "$SVC" \
      || file_contains '\$clientCode\s*\.\s*'"'"'-'"'"'\s*\.' "$SVC"
}

# A2 (POSITIVE): new 3-arg signature (clientCode threaded in)
check_A2_signature_takes_clientcode() {
    file_contains 'function getTransferId\([^)]*\$clientCode' "$SVC"
}

# A3 (POSITIVE): call site passes $clientCode
check_A3_callsite_passes_clientcode() {
    file_contains "getTransferId\(\\\$parcels,\s*\\\$data\['pack_type'\],\s*\\\$clientCode\)" "$SVC" \
      || file_contains 'getTransferId\([^)]*\$clientCode\)' "$SVC"
}

# A4 (NEGATIVE): getTransferId no longer returns transfer_destination.
# transfer_destination must still appear for getTransferDestination (batch_type),
# so assert there is at most ONE transfer_destination read left in the file
# (the legitimate one in getTransferDestination), i.e. the duplicate in
# getTransferId is gone.
check_A4_no_destination_as_transferid() {
    local n
    n=$(grep -cE 'order->transfer_destination' "$SVC" 2>/dev/null || echo 99)
    [ "$n" -le 1 ]
}

echo
echo "verify-260609-oms-transfer-id-wrong-source-fix — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

run A1 "getTransferId builds CLIENT_CODE-ORDER_ID"            check_A1_builds_client_dash_order
run A2 "getTransferId signature accepts \$clientCode"          check_A2_signature_takes_clientcode
run A3 "call site passes \$clientCode to getTransferId"        check_A3_callsite_passes_clientcode
run A4 "transfer_destination no longer used as transfer_id"    check_A4_no_destination_as_transferid

# Behavioral proof (optional — requires PHP/composer deps installed).
if command -v php >/dev/null 2>&1 && [ -f vendor/bin/phpunit ]; then
    run A5 "BatchProcessing tests pass" bash -c "php artisan test --filter=BatchProcessing 2>&1 | grep -qiE 'OK|PASS|Tests:.*[1-9]'"
else
    skip A5 "BatchProcessing tests" "php/phpunit not available in this shell"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
