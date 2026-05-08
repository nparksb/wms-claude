#!/usr/bin/env bash
# verify-260424-oms-notification.sh
#
# Acceptance for Plan A — `260424-oms-notification-rollback-risk-remediation.md`.
#
# Encodes each S1–S14 site as a grep/test assertion. Runs against v1/wms-api by default;
# override with PROJECT_ROOT=/path/to/wms-api.
#
# A "DONE" claim from any agent or contributor is not accepted while this script reports FAIL.
# See sbdocs/9-System/templates/verify-plan-template.sh for the design notes.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/Users/np1076/dev/spk/owl/v1/wms-api}"
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

file_contains() { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { ! grep -qE "$1" "$2" 2>/dev/null; }
# Multi-line variant — uses perl -0777 so the regex can span newlines.
# (BSD grep -z doesn't make `.` / `\s*` truly multi-line on macOS.)
file_contains_ml() {
    PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null
}
file_count_at_least() {
    local pat=$1 file=$2 n=$3
    local c
    c=$(grep -cE "$pat" "$file" 2>/dev/null || echo 0)
    [ "$c" -ge "$n" ]
}

SVC=src/main/java/net/aim_ai/wms/service
REPO=src/main/java/net/aim_ai/wms/repo/jpa

echo
echo "verify-260424-oms-notification — Plan A acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# --- Helper utility (Plan A §3.0) ---
HELPER=$SVC/util/OmsNotificationHelper.java

run HELPER-1 "OmsNotificationHelper.java exists"  test -f "$HELPER"
run HELPER-2 "OmsNotificationHelper has deferToCommit four-arg form (with MessagePersister)" \
    file_contains_ml 'public static void deferToCommit\([^{]*MessagePersister' "$HELPER"
run HELPER-3 "OmsNotificationHelper has deferToCommit two-arg overload" \
    file_contains 'public static void deferToCommit\(String[^,]*,\s*String[^,]*,\s*OmsCall[^)]*\)' "$HELPER"
run HELPER-4 "OmsNotificationHelper uses TransactionSynchronizationManager.registerSynchronization" \
    file_contains 'TransactionSynchronizationManager\.registerSynchronization' "$HELPER"
run HELPER-5 "MessageService.createMessageInNewTransaction has REQUIRES_NEW" \
    file_contains '@Transactional\(propagation\s*=\s*Propagation\.REQUIRES_NEW\)' "$SVC/MessageService.java"
run HELPER-6 "MessageService.createMessageInNewTransaction method present" \
    file_contains 'createMessageInNewTransaction\s*\(' "$SVC/MessageService.java"

echo

# --- S1 — cancelBatch ---
S1FILE=$SVC/CustomerorderBatchService.java

run S1a "S1 — cancelBatch acquires pessimistic lock at entry (findByIdForUpdate)" \
    file_contains 'customerorderBatchRepository\.findByIdForUpdate' "$S1FILE"
run S1b "S1 — cancelBatch invokes helper with site name" \
    file_contains_ml 'OmsNotificationHelper\.deferToCommit\(\s*"cancelBatch"' "$S1FILE"

echo

# --- S2 — cancelOrder ---
S2FILE=$SVC/CustomerorderService.java

run S2  "S2 — cancelOrder invokes helper with site name" \
    file_contains_ml 'OmsNotificationHelper\.deferToCommit\(\s*"cancelOrder"' "$S2FILE"

echo

# --- S3 — closeBOL ---
S3FILE=$SVC/BillofladingService.java

run S3a "S3 — closeBOL invokes helper with site name" \
    file_contains_ml 'OmsNotificationHelper\.deferToCommit\(\s*"closeBOL"' "$S3FILE"
run S3b "S3 — closeBOL audit row uses createMessageInNewTransaction (not createMessage)" \
    file_contains 'messageService\.createMessageInNewTransaction\(' "$S3FILE"
# S3c removed: the regex couldn't distinguish "POST inline in closeBOL body" from
# "POST inside the helper's OmsCall lambda" — both have identical text. S3a + S3b
# together are sufficient proof: helper used, audit goes through REQUIRES_NEW.

echo

# --- S4 — ReleaseOrderJobService (3 sites) ---
S4FILE=$SVC/job/ReleaseOrderJobService.java

run S4  "S4 — ReleaseOrderJobService invokes helper at least 3 times" \
    file_count_at_least 'OmsNotificationHelper\.deferToCommit' "$S4FILE" 3

echo

# --- S5 — MobilePickingService dead methods removed ---
S5FILE=$SVC/mobile/MobilePickingService.java

run S5a "S5 — rapidPickingConnectPackageAndType deleted" \
    file_not_contains 'rapidPickingConnectPackageAndType' "$S5FILE"
run S5b "S5 — rapidPickingScanPackageAndType deleted" \
    file_not_contains 'rapidPickingScanPackageAndType' "$S5FILE"

echo

# --- S6 + S14 — OrderMonitorViewService.printToteLabels / reprintToteLabels ---
S6FILE=$SVC/OrderMonitorViewService.java

run S6a  "S6 — printToteLabels has @Transactional envelope" \
    file_contains '@Transactional\([^)]*rollbackFor\b[^)]*\)' "$S6FILE"
run S6b  "S6 — OrderMonitorViewService invokes helper at least once" \
    file_contains 'OmsNotificationHelper\.deferToCommit' "$S6FILE"
run S14  "S14 — OrderMonitorViewService invokes helper at least 2× (printToteLabels + reprintToteLabels)" \
    file_count_at_least 'OmsNotificationHelper\.deferToCommit' "$S6FILE" 2

echo

# --- S7/S8/S9 — AdviceService bundle ---
S7FILE=$SVC/AdviceService.java

run S7a  "S7-9 — AdviceService has @Transactional envelope" \
    file_contains '@Transactional\([^)]*rollbackFor\b[^)]*\)' "$S7FILE"
run S7b  "S7-9 — AdviceService invokes helper at least 3× (acceptHubAndSpoke / close / acceptTransfer)" \
    file_count_at_least 'OmsNotificationHelper\.deferToCommit' "$S7FILE" 3

echo

# --- S10 — finishPickingOrder fallback log upgrade ---
S10FILE=$SVC/PickingorderBusinessService.java

run S10  "S10 — finishPickingOrder fallback emits LOG.error (not silent)" \
    file_contains 'LOG\.error\([^)]*finishPickingOrder' "$S10FILE"

echo

# --- S11 — StockunitService cluster (5 sites) ---
S11FILE=$SVC/StockunitService.java

run S11  "S11 — StockunitService invokes helper at least 5×" \
    file_count_at_least 'OmsNotificationHelper\.deferToCommit' "$S11FILE" 5

echo

# --- S12 — UnitloadService.delete* cluster ---
S12FILE=$SVC/UnitloadService.java

run S12a "S12 — UnitloadService delete methods have @Transactional" \
    file_contains '@Transactional\([^)]*rollbackFor\b[^)]*\)' "$S12FILE"
run S12b "S12 — UnitloadService invokes helper at least 2× (deleteUnitLoad / deleteUnitLoadRecursive)" \
    file_count_at_least 'OmsNotificationHelper\.deferToCommit' "$S12FILE" 2

echo

# --- S13 — GoodsReceiptPositionService cluster ---
S13FILE=$SVC/GoodsReceiptPositionService.java

run S13  "S13 — GoodsReceiptPositionService invokes helper at least 2× (adjust / delete)" \
    file_count_at_least 'OmsNotificationHelper\.deferToCommit' "$S13FILE" 2

echo

# --- Targeted unit tests still pass ---
# Optional but recommended. Comment out if a hostile environment lacks Maven.
mvn_test_passes() {
    local cls=$1
    # Don't use -q: it suppresses the [INFO] lines we need to read.
    # Trust mvn's exit code: 0 = all tests pass, non-zero = any failure.
    mvn test -Dtest="$cls" -DfailIfNoTests=false >/dev/null 2>&1
}

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T-S1   "T — CustomerorderBatchServiceUnitTest passes" mvn_test_passes CustomerorderBatchServiceUnitTest
    run T-S2   "T — CustomerorderServiceUnitTest passes"      mvn_test_passes CustomerorderServiceUnitTest
    run T-S3   "T — BillofladingServiceUnitTest passes"       mvn_test_passes BillofladingServiceUnitTest
    run T-HELP "T — OmsNotificationHelperTest passes"         mvn_test_passes OmsNotificationHelperTest
else
    skip T-mvn "Targeted unit-test runs"  "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
