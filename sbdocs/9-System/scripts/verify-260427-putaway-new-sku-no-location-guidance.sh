#!/usr/bin/env bash
# verify-260427-putaway-new-sku-no-location-guidance.sh
# Machine-checkable acceptance for:
#   260427-putaway-new-sku-no-location-guidance.md
#
# Run from anywhere:
#   bash sbdocs/9-System/scripts/verify-260427-putaway-new-sku-no-location-guidance.sh
#
# Exit code 0 = all checks pass.

set -u

UI_ROOT="${UI_ROOT:-/Users/np1076/dev/spk/owl/v1/wms-mobile-ui}"
API_ROOT="${API_ROOT:-/Users/np1076/dev/spk/owl/v1/wms-api}"
SCAN_FLOWBIN="$UI_ROOT/components/putaway/scanFlowBin.vue"
FLA_SERVICE="$API_ROOT/src/main/java/net/aim_ai/wms/service/FixLocationAssignmentService.java"
PUTAWAY_SERVICE="$API_ROOT/src/main/java/net/aim_ai/wms/service/mobile/MobilePutAwayService.java"

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

file_contains()     { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }

echo
echo "verify-260427-putaway-new-sku-no-location-guidance — acceptance checks"
echo "  UI_ROOT=$UI_ROOT"
echo "  API_ROOT=$API_ROOT"
echo

# --- Fix A: scanFlowBin.vue guidance for new SKUs ---

check_A1_computed() {
    file_contains 'hasNoSuggestedLocation\s*\(\s*\)' "$SCAN_FLOWBIN"
}
run A1 "Fix A — hasNoSuggestedLocation computed property exists" check_A1_computed

check_A2_alert() {
    file_contains 'v-if="hasNoSuggestedLocation"' "$SCAN_FLOWBIN"
}
run A2 "Fix A — v-alert v-if=hasNoSuggestedLocation present in template" check_A2_alert

check_A3_label() {
    file_contains 'hasNoSuggestedLocation.*Scan Flowbin|Scan Flowbin.*hasNoSuggestedLocation' "$SCAN_FLOWBIN"
}
run A3 "Fix A — scan label is dynamic (references hasNoSuggestedLocation)" check_A3_label

echo

# --- Fix B: null-safe sysprop parsing in FixLocationAssignmentService ---

check_B1_null_safe_parse() {
    # Old pattern: Long.parseLong(losSyspropRepository.findSysvalueBySyskey(...)) with no null guard
    file_not_contains 'Long\.parseLong\(\s*losSyspropRepository\.findSysvalueBySyskey' "$FLA_SERVICE"
}
run B1 "Fix B — unguarded Long.parseLong(findSysvalueBySyskey) removed" check_B1_null_safe_parse

check_B2_orElseThrow() {
    file_contains 'findByName.*UNIT_LOAD_TYPE_PICKLOCATION.*orElseThrow|orElseThrow.*UNIT_LOAD_TYPE_PICKLOCATION' "$FLA_SERVICE"
}
run B2 "Fix B — findByName(UNIT_LOAD_TYPE_PICKLOCATION) uses orElseThrow" check_B2_orElseThrow

echo

# --- Fix C: @Transactional on storeBoxOnLocation ---

check_C1_transactional() {
    file_contains '@Transactional.*rollbackFor' "$PUTAWAY_SERVICE"
}
run C1 "Fix C — @Transactional(rollbackFor) present in MobilePutAwayService" check_C1_transactional

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
echo
[ "$FAIL" -eq 0 ]
