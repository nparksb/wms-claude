#!/usr/bin/env bash
# verify-SBDEV-1921-order-cancellation-reversal-workflow.sh
# Machine-checkable acceptance / regression guard for plan
# SBDEV-1921-order-cancellation-reversal-workflow.md.
#
# The WMS code (Phases 1-4) is already merged to develop (wms2-api bf14f6d,
# wms2-mobile-ui c7f50bb), so this script is a REGRESSION GUARD: it asserts the
# merged contract is still present. It also reports (non-fatally) on the two
# CLOSURE blockers that live outside wms2-api: the paired OMS endpoint and the
# per-environment sysprop URL.
#
#   $ PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
#     MOBILE_ROOT=/home/nampark/dev/wms-claude/v2/wms2-mobile-ui \
#     OMS_ROOT=/home/nampark/dev/wms-claude/v2/oms-laravel-api \
#       bash sbdocs/9-System/scripts/verify-SBDEV-1921-order-cancellation-reversal-workflow.sh
#
# Set RUN_TESTS=1 to also run the targeted Maven suites (§14 step 2). Default off
# (fast static checks only). Exit 0 iff every structural check passes.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
MOBILE_ROOT="${MOBILE_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-mobile-ui}"
OMS_ROOT="${OMS_ROOT:-/home/nampark/dev/wms-claude/v2/oms-laravel-api}"
RUN_TESTS="${RUN_TESTS:-0}"

cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi
}
file_contains() { grep -qE "$1" "$2" 2>/dev/null; }
exists()        { [ -f "$1" ]; }
mvn_test_passes() {
    mvn test -Dtest="$1" -DfailIfNoTests=false 2>&1 \
        | grep -qE "Tests run: [1-9][0-9]*, Failures: 0, Errors: 0"
}

CONST=src/main/java/net/aim_ai/wms/service/WmsConstants.java
# Phase-1 DDL originally landed as V2.1.12__add_cancellation_reversal_log_and_grant.sql.
# That file no longer exists: the V2.1.x migrations were squashed into the
# V2.2.00 baseline (verified 2026-07-27 — table @810, partial index @3866,
# MOBILE_UI_VIEW_CANCELLATION function seed @2818). Assert against whichever
# migration actually carries the DDL so the C2 checks stay meaningful across
# future baseline squashes.
MIG=$(ls src/main/resources/db/migration/V2.1.12__add_cancellation_reversal_log_and_grant.sql 2>/dev/null \
      || grep -rl 'customerorder_cancellation_log' src/main/resources/db/migration/ 2>/dev/null | head -1)
MIG="${MIG:-src/main/resources/db/migration/V2.1.12__add_cancellation_reversal_log_and_grant.sql}"
ENTITY=src/main/java/net/aim_ai/wms/model/CustomerorderCancellationLog.java
REPO=src/main/java/net/aim_ai/wms/repo/jpa/CustomerorderCancellationLogRepository.java
LOGSVC=src/main/java/net/aim_ai/wms/service/CancellationLogService.java
REVSVC=src/main/java/net/aim_ai/wms/service/CancellationReversalService.java
CTRL=src/main/java/net/aim_ai/wms/controller/OrderCancellationController.java
POSSVC=src/main/java/net/aim_ai/wms/service/CustomerorderPositionService.java

# --- C1: new MessageProcessType + sysprop (Phase 3) ---
check_C1_type() { file_contains 'ORDER_BATCH_REVERSAL_COMPLETED\s*=\s*"ORDER_BATCH_REVERSAL_COMPLETED"' "$CONST"; }
check_C1_key()  { file_contains 'SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED_URL_KEY\s*=\s*"WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED"' "$CONST"; }
check_C1_role() { file_contains 'MOBILE_UI_VIEW_CANCELLATION' "$CONST"; }

# --- C2: Flyway migration V2.1.12 (Phase 1) ---
check_C2_file()  { exists "$MIG"; }
check_C2_table() { file_contains 'customerorder_cancellation_log' "$MIG"; }
check_C2_index() { file_contains 'idx_cancel_log_reversal_pending' "$MIG"; }
check_C2_func()  { file_contains 'MOBILE_UI_VIEW_CANCELLATION' "$MIG"; }

# --- C3: entity + repository + log service (Phase 1) ---
check_C3_entity() { exists "$ENTITY"; }
check_C3_repo()   { exists "$REPO"; }
check_C3_logsvc() { exists "$LOGSVC"; }

# --- C4: guard relaxation + header-promotion fix (Phase 2) ---
# Cancellation cutoff moved to PACKED; buggy allMatch(>=FINISHED)-only promotion replaced.
check_C4_packed() { file_contains 'State\.PACKED' "$POSSVC"; }

# --- C5: reversal service drives stock move + reversal-completed outbox (Phase 3) ---
check_C5_complete() { file_contains 'completeReversal' "$REVSVC"; }
check_C5_transfer() { file_contains 'transferStock' "$REVSVC"; }
check_C5_outbox()   { file_contains 'ORDER_BATCH_REVERSAL_COMPLETED' "$REVSVC"; }

# --- C6: mobile API controller — 5 endpoints under /v3/cancellation (Phase 3) ---
check_C6_base()  { file_contains '/v3/cancellation' "$CTRL"; }
check_C6_scan()  { file_contains 'scan-tote' "$CTRL"; }
check_C6_init()  { file_contains '/initiate' "$CTRL"; }
check_C6_comp()  { file_contains '/complete' "$CTRL"; }

# --- C7: mobile-UI artifacts (Phase 4) ---
check_C7_page()  { exists "$MOBILE_ROOT/pages/cancellation.vue"; }
check_C7_store() { exists "$MOBILE_ROOT/store/cancellation.js"; }
# The menu entry's display title was changed from 'Cancellation Process' to
# 'Return to Stock (RTS)' (verified 2026-07-27, store/home.js:88-93). Assert on
# the route + role instead — those are the contract, the label is cosmetic.
check_C7_menu()  { file_contains 'MOBILE_UI_VIEW_CANCELLATION' "$MOBILE_ROOT/store/home.js" \
                   && file_contains '"/cancellation"' "$MOBILE_ROOT/store/home.js"; }

# --- C8 (optional): targeted Maven suites (§14 step 2) ---
check_C8_tests() {
    mvn_test_passes 'CustomerorderPositionServiceTest,CustomerorderServiceTest,CancellationLogServiceTest,CancellationReversalServiceTest,OrderCancellationControllerTest'
}

echo
echo "verify-SBDEV-1921-order-cancellation-reversal-workflow — regression guard"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  MOBILE_ROOT=$MOBILE_ROOT"
echo

run C1-type  "C1 — ORDER_BATCH_REVERSAL_COMPLETED process type"   check_C1_type
run C1-key   "C1 — reversal-completed sysprop key"                check_C1_key
run C1-role  "C1 — MOBILE_UI_VIEW_CANCELLATION constant"          check_C1_role
run C2-file  "C2 — cancellation-log migration present (V2.1.12 or squashed baseline)" check_C2_file
run C2-table "C2 — creates customerorder_cancellation_log"        check_C2_table
run C2-index "C2 — partial index idx_cancel_log_reversal_pending" check_C2_index
run C2-func  "C2 — seeds MOBILE_UI_VIEW_CANCELLATION function"    check_C2_func
run C3-ent   "C3 — CustomerorderCancellationLog entity"           check_C3_entity
run C3-repo  "C3 — CustomerorderCancellationLogRepository"        check_C3_repo
run C3-svc   "C3 — CancellationLogService"                        check_C3_logsvc
run C4-pack  "C4 — guard uses PACKED cutoff (Phase 2)"            check_C4_packed
run C5-comp  "C5 — CancellationReversalService.completeReversal"  check_C5_complete
run C5-xfer  "C5 — reversal calls transferStock (stock-to-source)" check_C5_transfer
run C5-obx   "C5 — reversal enqueues ORDER_BATCH_REVERSAL_COMPLETED" check_C5_outbox
run C6-base  "C6 — controller mapped at /v3/cancellation"         check_C6_base
run C6-scan  "C6 — scan-tote endpoint"                            check_C6_scan
run C6-init  "C6 — initiate endpoint"                             check_C6_init
run C6-comp  "C6 — complete endpoint"                             check_C6_comp
run C7-page  "C7 — mobile pages/cancellation.vue"                 check_C7_page
run C7-store "C7 — mobile store/cancellation.js"                  check_C7_store
run C7-menu  "C7 — /cancellation menu item + role gate"          check_C7_menu

if [ "$RUN_TESTS" = "1" ]; then
    run C8-tests "C8 — targeted Maven suites pass"                check_C8_tests
else
    printf "  SKIP  %-10s  %s\n" "C8-tests" "C8 — Maven suites (set RUN_TESTS=1 to run)"; SKIP=$((SKIP+1))
fi

# --- Closure-blocker report (NON-FATAL — informational; lives outside wms2-api) ---
echo
echo "Closure blockers (informational — do NOT affect pass/fail):"
if grep -rqiE "batchReversalCompleted|ORDER_BATCH_REVERSAL_COMPLETED" "$OMS_ROOT/app" "$OMS_ROOT/routes" 2>/dev/null; then
    echo "  [ok]   OMS endpoint batchReversalCompleted appears present in oms-laravel-api"
else
    echo "  [TODO] OMS endpoint POST /services/call/batchReversalCompleted NOT found in oms-laravel-api (Q2/F1)"
fi
if grep -q 'oms-XXXXX' "$CONST" 2>/dev/null; then
    echo "  [TODO] sysprop default still the oms-XXXXX placeholder — set real per-env URL before prod"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
