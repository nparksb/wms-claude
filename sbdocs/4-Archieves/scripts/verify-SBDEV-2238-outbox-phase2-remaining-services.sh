#!/usr/bin/env bash
# verify-SBDEV-2238-outbox-phase2-remaining-services.sh
#
# Static-verification harness for the SBDEV-2238 Phase-2 outbox migration plan
# (5 remaining service call sites: cancelOrder / cancelBatch /
# acceptHubAndSpokeAdvice / closeAdvice / acceptTransferAdvice).
#
# Runs entirely from grep + file-existence assertions. No DB connection
# required — DB-side verification happens in the three integration test
# classes and the manual smoke step (§6 step 6 of the plan).
#
# Usage:
#   bash sbdocs/9-System/scripts/verify-SBDEV-2238-outbox-phase2-remaining-services.sh
#
# Exit codes:
#   0 = all checks passed
#   non-zero = at least one check failed (count of failures)

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
API_ROOT="$REPO_ROOT/v2/wms2-api"
SRC="$API_ROOT/src/main/java/net/aim_ai/wms"
TEST="$API_ROOT/src/test/java/net/aim_ai/wms"
MIG="$API_ROOT/src/main/resources/db/migration"

CO_SVC="$SRC/service/CustomerorderService.java"
COB_SVC="$SRC/service/CustomerorderBatchService.java"
ADV_SVC="$SRC/service/AdviceService.java"

FAIL=0
PASS=0
SKIP=0

check()    { local name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "PASS  $name"; PASS=$((PASS+1)); else echo "FAIL  $name"; FAIL=$((FAIL+1)); fi; }
checkneg() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "FAIL  $name"; FAIL=$((FAIL+1)); else echo "PASS  $name"; PASS=$((PASS+1)); fi; }
skip()     { local name="$1"; local reason="$2"; echo "SKIP  $name  ($reason)"; SKIP=$((SKIP+1)); }
section()  { echo; echo "=== $1 ==="; }

# --- helpers --------------------------------------------------------------

# Match a regex (extended) anywhere in a file.
file_contains() { grep -qE "$1" "$2"; }

# Assert a regex does NOT appear.
file_not_contains() { ! grep -qE "$1" "$2"; }

# Extract a method body by name. Finds the first `public ... <method>(` line
# and prints from there until the matching closing brace at 4-space indent.
method_body() {
    local file="$1"; local method="$2"
    awk -v m="$method" '
        $0 ~ ("public[[:space:]].*[[:space:]]" m "[[:space:]]*\\(") {flag=1}
        flag {print}
        flag && /^    \}/ {flag=0; exit}
    ' "$file"
}

echo
echo "verify-SBDEV-2238-outbox-phase2-remaining-services — running acceptance checks"
echo "  REPO_ROOT=$REPO_ROOT"
echo "  API_ROOT=$API_ROOT"
echo

# --- 0. Prerequisites (SBDEV-2221 + SBDEV-2238-4.1 must be merged) --------

section "0. Prerequisites — SBDEV-2221 outbox infrastructure + SBDEV-2238-4.1 pilot must be present"

check "Prereq: OutboxMessage entity present" \
    test -f "$SRC/model/OutboxMessage.java"
check "Prereq: OutboxService present" \
    test -f "$SRC/service/OutboxService.java"
check "Prereq: OutboxDispatcherJob present" \
    test -f "$SRC/schedulejob/OutboxDispatcherJob.java"
check "Prereq: OutboxMessageRepository present" \
    test -f "$SRC/repo/jpa/OutboxMessageRepository.java"
check "Prereq: V1.1.16__add_outbox_message.sql present" \
    test -f "$MIG/V1.1.16__add_outbox_message.sql"
check "Prereq: AdvisoryLockService declares OUTBOX_DISPATCHER = 100008L" \
    grep -qE "OUTBOX_DISPATCHER[[:space:]]*=[[:space:]]*100008L" "$SRC/service/AdvisoryLockService.java"
check "Prereq: SBDEV-2238-4.1 pilot — BillofladingService.closeBOL calls outboxService.enqueue" \
    grep -qE "outboxService\.enqueue" "$SRC/service/BillofladingService.java"

# --- 1. Fix A — CustomerorderService.cancelOrder --------------------------

section "1. Fix A — CustomerorderService.cancelOrder uses outbox, not sendAfterCommit"

check "Fix A: CustomerorderService imports OutboxMessage" \
    grep -qE "import[[:space:]]+.*\.model\.OutboxMessage;" "$CO_SVC"
check "Fix A: CustomerorderService imports MeterRegistry" \
    grep -qE "import[[:space:]]+io\.micrometer\.core\.instrument\.MeterRegistry;" "$CO_SVC"
check "Fix A: CustomerorderService declares static final ObjectMapper MAPPER" \
    grep -qE "private[[:space:]]+static[[:space:]]+final[[:space:]]+ObjectMapper[[:space:]]+MAPPER" "$CO_SVC"
check "Fix A: CustomerorderService MAPPER uses NON_NULL inclusion" \
    grep -qE "JsonInclude\.Include\.NON_NULL" "$CO_SVC"
check "Fix A: CustomerorderService constructor declares an OutboxService parameter" \
    grep -qE "OutboxService[[:space:]]+outboxService" "$CO_SVC"
check "Fix A: CustomerorderService constructor declares a MeterRegistry parameter" \
    grep -qE "MeterRegistry[[:space:]]+meterRegistry" "$CO_SVC"

check "Fix A: cancelOrder calls outboxService.enqueue" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]cancelOrder[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$CO_SVC"'" | grep -qE "outboxService\\.enqueue\\("'

check "Fix A: cancelOrder enqueue sets aggregateType=\"CUSTOMER_ORDER\"" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]cancelOrder[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$CO_SVC"'" | grep -qE "aggregateType\\([[:space:]]*\"CUSTOMER_ORDER\"[[:space:]]*\\)"'

check "Fix A: cancelOrder enqueue sets processType=ORDER_BATCH_CANCELLED_FROM_WMS" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]cancelOrder[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$CO_SVC"'" | grep -qE "processType\\(.*ORDER_BATCH_CANCELLED_FROM_WMS"'

checkneg "Fix A NEGATIVE: cancelOrder does NOT set idempotencyKey explicitly (auto-generated by OutboxService)" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]cancelOrder[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$CO_SVC"'" | grep -qE "\\.idempotencyKey\\("'

checkneg "Fix A NEGATIVE: cancelOrder no longer calls sendAfterCommit with ORDER_BATCH_CANCELLED_FROM_WMS" \
    bash -c 'body=$(awk "/public[[:space:]].*[[:space:]]cancelOrder[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$CO_SVC"'"); echo "$body" | grep -qE "omsNotificationService\\.sendAfterCommit\\(" && echo "$body" | grep -qE "ORDER_BATCH_CANCELLED_FROM_WMS"'

check "Fix A: cancelOrder increments wms2.outbox.serialize_failed with snake_case tag keys" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]cancelOrder[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$CO_SVC"'" | grep -qE "\"aggregate_type\""'

check "Fix A: cancelOrder throws FacadeException on IOException (matching pilot rollback policy)" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]cancelOrder[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$CO_SVC"'" | grep -qE "throw new FacadeException"'

checkneg "Fix A NEGATIVE: no camelCase aggregateType tag key in cancelOrder" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]cancelOrder[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$CO_SVC"'" | grep -qE "\"aggregateType\""'

# --- 2. Fix B — CustomerorderBatchService.cancelBatch ---------------------

section "2. Fix B — CustomerorderBatchService.cancelBatch uses outbox, not sendAfterCommit"

check "Fix B: CustomerorderBatchService imports OutboxMessage" \
    grep -qE "import[[:space:]]+.*\.model\.OutboxMessage;" "$COB_SVC"
check "Fix B: CustomerorderBatchService imports MeterRegistry" \
    grep -qE "import[[:space:]]+io\.micrometer\.core\.instrument\.MeterRegistry;" "$COB_SVC"
check "Fix B: CustomerorderBatchService declares static final ObjectMapper MAPPER" \
    grep -qE "private[[:space:]]+static[[:space:]]+final[[:space:]]+ObjectMapper[[:space:]]+MAPPER" "$COB_SVC"
check "Fix B: CustomerorderBatchService MAPPER uses NON_NULL inclusion" \
    grep -qE "JsonInclude\.Include\.NON_NULL" "$COB_SVC"
check "Fix B: CustomerorderBatchService constructor declares an OutboxService parameter" \
    grep -qE "OutboxService[[:space:]]+outboxService" "$COB_SVC"
check "Fix B: CustomerorderBatchService constructor declares a MeterRegistry parameter" \
    grep -qE "MeterRegistry[[:space:]]+meterRegistry" "$COB_SVC"

check "Fix B: cancelBatch calls outboxService.enqueue" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]cancelBatch[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$COB_SVC"'" | grep -qE "outboxService\\.enqueue\\("'

check "Fix B: cancelBatch enqueue sets aggregateType=\"CUSTOMER_ORDER_BATCH\"" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]cancelBatch[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$COB_SVC"'" | grep -qE "aggregateType\\([[:space:]]*\"CUSTOMER_ORDER_BATCH\"[[:space:]]*\\)"'

check "Fix B: cancelBatch enqueue sets processType=ORDER_BATCH_CANCELLED_FROM_WMS" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]cancelBatch[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$COB_SVC"'" | grep -qE "processType\\(.*ORDER_BATCH_CANCELLED_FROM_WMS"'

checkneg "Fix B NEGATIVE: cancelBatch does NOT set idempotencyKey explicitly (auto-generated by OutboxService)" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]cancelBatch[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$COB_SVC"'" | grep -qE "\\.idempotencyKey\\("'

checkneg "Fix B NEGATIVE: cancelBatch no longer calls sendAfterCommit with ORDER_BATCH_CANCELLED_FROM_WMS" \
    bash -c 'body=$(awk "/public[[:space:]].*[[:space:]]cancelBatch[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$COB_SVC"'"); echo "$body" | grep -qE "omsNotificationService\\.sendAfterCommit\\(" && echo "$body" | grep -qE "ORDER_BATCH_CANCELLED_FROM_WMS"'

check "Fix B: cancelBatch increments wms2.outbox.serialize_failed with snake_case tag keys" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]cancelBatch[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$COB_SVC"'" | grep -qE "\"aggregate_type\""'

check "Fix B: cancelBatch throws FacadeException on IOException (matching pilot rollback policy)" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]cancelBatch[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$COB_SVC"'" | grep -qE "throw new FacadeException"'

checkneg "Fix B NEGATIVE: no camelCase aggregateType tag key in cancelBatch" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]cancelBatch[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$COB_SVC"'" | grep -qE "\"aggregateType\""'

# --- 3. Fix C — AdviceService.acceptHubAndSpokeAdvice ---------------------

section "3. Fix C — AdviceService.acceptHubAndSpokeAdvice uses outbox, not sendAfterCommit"

check "Fix C: AdviceService imports OutboxMessage" \
    grep -qE "import[[:space:]]+.*\.model\.OutboxMessage;" "$ADV_SVC"
check "Fix C: AdviceService imports MeterRegistry" \
    grep -qE "import[[:space:]]+io\.micrometer\.core\.instrument\.MeterRegistry;" "$ADV_SVC"
check "Fix C: AdviceService declares static final ObjectMapper MAPPER" \
    grep -qE "private[[:space:]]+static[[:space:]]+final[[:space:]]+ObjectMapper[[:space:]]+MAPPER" "$ADV_SVC"
check "Fix C: AdviceService MAPPER uses NON_NULL inclusion" \
    grep -qE "JsonInclude\.Include\.NON_NULL" "$ADV_SVC"
check "Fix C: AdviceService constructor declares an OutboxService parameter" \
    grep -qE "OutboxService[[:space:]]+outboxService" "$ADV_SVC"
check "Fix C: AdviceService constructor declares a MeterRegistry parameter" \
    grep -qE "MeterRegistry[[:space:]]+meterRegistry" "$ADV_SVC"

check "Fix C: acceptHubAndSpokeAdvice calls outboxService.enqueue" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]acceptHubAndSpokeAdvice[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'" | grep -qE "outboxService\\.enqueue\\("'

check "Fix C: acceptHubAndSpokeAdvice enqueue sets aggregateType=\"ADVICE\"" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]acceptHubAndSpokeAdvice[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'" | grep -qE "aggregateType\\([[:space:]]*\"ADVICE\"[[:space:]]*\\)"'

check "Fix C: acceptHubAndSpokeAdvice enqueue sets processType=ADVICE_HUB_AND_SPOKE_RECEIVED" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]acceptHubAndSpokeAdvice[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'" | grep -qE "processType\\(.*ADVICE_HUB_AND_SPOKE_RECEIVED"'

checkneg "Fix C NEGATIVE: acceptHubAndSpokeAdvice does NOT set idempotencyKey explicitly (auto-generated by OutboxService)" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]acceptHubAndSpokeAdvice[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'" | grep -qE "\\.idempotencyKey\\("'

checkneg "Fix C NEGATIVE: acceptHubAndSpokeAdvice no longer calls sendAfterCommit with ADVICE_HUB_AND_SPOKE_RECEIVED" \
    bash -c 'body=$(awk "/public[[:space:]].*[[:space:]]acceptHubAndSpokeAdvice[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'"); echo "$body" | grep -qE "omsNotificationService\\.sendAfterCommit\\(" && echo "$body" | grep -qE "ADVICE_HUB_AND_SPOKE_RECEIVED"'

check "Fix C: acceptHubAndSpokeAdvice increments wms2.outbox.serialize_failed with snake_case tag keys" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]acceptHubAndSpokeAdvice[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'" | grep -qE "\"aggregate_type\""'

check "Fix C: acceptHubAndSpokeAdvice throws FacadeException on IOException (matching pilot rollback policy)" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]acceptHubAndSpokeAdvice[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'" | grep -qE "throw new FacadeException"'

checkneg "Fix C NEGATIVE: no camelCase aggregateType tag key in acceptHubAndSpokeAdvice" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]acceptHubAndSpokeAdvice[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'" | grep -qE "\"aggregateType\""'

# --- 4. Fix D — AdviceService.close ---------------------------------------

section "4. Fix D — AdviceService.close uses outbox, not sendAfterCommit"

check "Fix D: AdviceService.close calls outboxService.enqueue" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]close[[:space:]]*\\([[:space:]]*Advice[[:space:]]+/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'" | grep -qE "outboxService\\.enqueue\\("'

check "Fix D: AdviceService.close enqueue sets processType=ADVICE_CLOSE" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]close[[:space:]]*\\([[:space:]]*Advice[[:space:]]+/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'" | grep -qE "processType\\(.*ADVICE_CLOSE"'

checkneg "Fix D NEGATIVE: AdviceService.close does NOT set idempotencyKey explicitly (auto-generated by OutboxService)" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]close[[:space:]]*\\([[:space:]]*Advice[[:space:]]+/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'" | grep -qE "\\.idempotencyKey\\("'

checkneg "Fix D NEGATIVE: AdviceService.close no longer calls sendAfterCommit with ADVICE_CLOSE" \
    bash -c 'body=$(awk "/public[[:space:]].*[[:space:]]close[[:space:]]*\\([[:space:]]*Advice[[:space:]]+/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'"); echo "$body" | grep -qE "omsNotificationService\\.sendAfterCommit\\(" && echo "$body" | grep -qE "ADVICE_CLOSE"'

check "Fix D: AdviceService.close increments wms2.outbox.serialize_failed with snake_case tag keys" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]close[[:space:]]*\\([[:space:]]*Advice[[:space:]]+/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'" | grep -qE "\"aggregate_type\""'

check "Fix D: AdviceService.close throws FacadeException on IOException (matching pilot rollback policy)" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]close[[:space:]]*\\([[:space:]]*Advice[[:space:]]+/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'" | grep -qE "throw new FacadeException"'

checkneg "Fix D NEGATIVE: no camelCase aggregateType tag key in AdviceService.close" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]close[[:space:]]*\\([[:space:]]*Advice[[:space:]]+/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'" | grep -qE "\"aggregateType\""'

# --- 5. Fix E — AdviceService.acceptTransferAdvice ------------------------

section "5. Fix E — AdviceService.acceptTransferAdvice uses outbox, not sendAfterCommit"

check "Fix E: acceptTransferAdvice calls outboxService.enqueue" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]acceptTransferAdvice[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'" | grep -qE "outboxService\\.enqueue\\("'

check "Fix E: acceptTransferAdvice enqueue sets processType=ADVICE_ACCEPT_TRANSFER" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]acceptTransferAdvice[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'" | grep -qE "processType\\(.*ADVICE_ACCEPT_TRANSFER"'

checkneg "Fix E NEGATIVE: acceptTransferAdvice does NOT set idempotencyKey explicitly (auto-generated by OutboxService)" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]acceptTransferAdvice[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'" | grep -qE "\\.idempotencyKey\\("'

checkneg "Fix E NEGATIVE: acceptTransferAdvice no longer calls sendAfterCommit with ADVICE_ACCEPT_TRANSFER" \
    bash -c 'body=$(awk "/public[[:space:]].*[[:space:]]acceptTransferAdvice[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'"); echo "$body" | grep -qE "omsNotificationService\\.sendAfterCommit\\(" && echo "$body" | grep -qE "ADVICE_ACCEPT_TRANSFER"'

check "Fix E: acceptTransferAdvice increments wms2.outbox.serialize_failed with snake_case tag keys" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]acceptTransferAdvice[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'" | grep -qE "\"aggregate_type\""'

check "Fix E: acceptTransferAdvice throws FacadeException on IOException (matching pilot rollback policy)" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]acceptTransferAdvice[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'" | grep -qE "throw new FacadeException"'

checkneg "Fix E NEGATIVE: no camelCase aggregateType tag key in acceptTransferAdvice" \
    bash -c 'awk "/public[[:space:]].*[[:space:]]acceptTransferAdvice[[:space:]]*\\(/{f=1} f{print} f && /^    \\}/{f=0; exit}" "'"$ADV_SVC"'" | grep -qE "\"aggregateType\""'

# --- 6. v2 constraint cross-checks ----------------------------------------

section "6. v2 constraint cross-checks (all 5 sites still on tenantTransactionManager)"

check "CustomerorderService.cancelOrder still @Transactional(tenantTransactionManager)" \
    grep -qE "tenantTransactionManager" "$CO_SVC"
check "CustomerorderBatchService.cancelBatch still @Transactional(tenantTransactionManager)" \
    grep -qE "tenantTransactionManager" "$COB_SVC"
check "AdviceService methods still @Transactional(tenantTransactionManager)" \
    grep -qE "tenantTransactionManager" "$ADV_SVC"

# --- 7. Unit + integration tests ------------------------------------------

section "7. Unit + integration tests"

check "CustomerorderServiceUnitTest exists" \
    test -f "$TEST/unit/service/CustomerorderServiceUnitTest.java"
check "CustomerorderServiceUnitTest: cancelOrder_enqueuesOutboxMessageWithExpectedFields" \
    grep -qE "cancelOrder_enqueuesOutboxMessageWithExpectedFields" "$TEST/unit/service/CustomerorderServiceUnitTest.java"
check "CustomerorderServiceUnitTest: cancelOrder_doesNotCallSendAfterCommitForProcessType" \
    grep -qE "cancelOrder_doesNotCallSendAfterCommitForProcessType" "$TEST/unit/service/CustomerorderServiceUnitTest.java"
check "CustomerorderServiceUnitTest: cancelOrder_incrementsSerializeFailedCounterOnIOException" \
    grep -qE "cancelOrder_incrementsSerializeFailedCounterOnIOException" "$TEST/unit/service/CustomerorderServiceUnitTest.java"

check "CustomerorderBatchServiceUnitTest exists" \
    test -f "$TEST/unit/service/CustomerorderBatchServiceUnitTest.java"
check "CustomerorderBatchServiceUnitTest: cancelBatch_enqueuesOutboxMessageWithExpectedFields" \
    grep -qE "cancelBatch_enqueuesOutboxMessageWithExpectedFields" "$TEST/unit/service/CustomerorderBatchServiceUnitTest.java"
check "CustomerorderBatchServiceUnitTest: cancelBatch_doesNotCallSendAfterCommitForProcessType" \
    grep -qE "cancelBatch_doesNotCallSendAfterCommitForProcessType" "$TEST/unit/service/CustomerorderBatchServiceUnitTest.java"
check "CustomerorderBatchServiceUnitTest: cancelBatch_incrementsSerializeFailedCounterOnIOException" \
    grep -qE "cancelBatch_incrementsSerializeFailedCounterOnIOException" "$TEST/unit/service/CustomerorderBatchServiceUnitTest.java"

check "AdviceServiceUnitTest exists" \
    test -f "$TEST/unit/service/AdviceServiceUnitTest.java"
check "AdviceServiceUnitTest: acceptHubAndSpokeAdvice_enqueuesOutboxMessageWithExpectedFields" \
    grep -qE "acceptHubAndSpokeAdvice_enqueuesOutboxMessageWithExpectedFields" "$TEST/unit/service/AdviceServiceUnitTest.java"
check "AdviceServiceUnitTest: acceptHubAndSpokeAdvice_doesNotCallSendAfterCommitForProcessType" \
    grep -qE "acceptHubAndSpokeAdvice_doesNotCallSendAfterCommitForProcessType" "$TEST/unit/service/AdviceServiceUnitTest.java"
check "AdviceServiceUnitTest: acceptHubAndSpokeAdvice_incrementsSerializeFailedCounterOnIOException" \
    grep -qE "acceptHubAndSpokeAdvice_incrementsSerializeFailedCounterOnIOException" "$TEST/unit/service/AdviceServiceUnitTest.java"
check "AdviceServiceUnitTest: close_enqueuesOutboxMessageWithExpectedFields" \
    grep -qE "close_enqueuesOutboxMessageWithExpectedFields" "$TEST/unit/service/AdviceServiceUnitTest.java"
check "AdviceServiceUnitTest: close_doesNotCallSendAfterCommitForProcessType" \
    grep -qE "close_doesNotCallSendAfterCommitForProcessType" "$TEST/unit/service/AdviceServiceUnitTest.java"
check "AdviceServiceUnitTest: close_incrementsSerializeFailedCounterOnIOException" \
    grep -qE "close_incrementsSerializeFailedCounterOnIOException" "$TEST/unit/service/AdviceServiceUnitTest.java"
check "AdviceServiceUnitTest: acceptTransferAdvice_enqueuesOutboxMessageWithExpectedFields" \
    grep -qE "acceptTransferAdvice_enqueuesOutboxMessageWithExpectedFields" "$TEST/unit/service/AdviceServiceUnitTest.java"
check "AdviceServiceUnitTest: acceptTransferAdvice_doesNotCallSendAfterCommitForProcessType" \
    grep -qE "acceptTransferAdvice_doesNotCallSendAfterCommitForProcessType" "$TEST/unit/service/AdviceServiceUnitTest.java"
check "AdviceServiceUnitTest: acceptTransferAdvice_incrementsSerializeFailedCounterOnIOException" \
    grep -qE "acceptTransferAdvice_incrementsSerializeFailedCounterOnIOException" "$TEST/unit/service/AdviceServiceUnitTest.java"

check "CustomerorderOutboxIntegrationTest exists" \
    test -f "$TEST/integration/CustomerorderOutboxIntegrationTest.java"
check "CustomerorderOutboxIntegrationTest is @Testcontainers" \
    grep -qE "@Testcontainers" "$TEST/integration/CustomerorderOutboxIntegrationTest.java"
check "CustomerorderBatchOutboxIntegrationTest exists" \
    test -f "$TEST/integration/CustomerorderBatchOutboxIntegrationTest.java"
check "CustomerorderBatchOutboxIntegrationTest is @Testcontainers" \
    grep -qE "@Testcontainers" "$TEST/integration/CustomerorderBatchOutboxIntegrationTest.java"
check "AdviceOutboxIntegrationTest exists" \
    test -f "$TEST/integration/AdviceOutboxIntegrationTest.java"
check "AdviceOutboxIntegrationTest is @Testcontainers" \
    grep -qE "@Testcontainers" "$TEST/integration/AdviceOutboxIntegrationTest.java"

# --- Summary -------------------------------------------------------------

echo
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "SKIP: $SKIP"
exit "$FAIL"
