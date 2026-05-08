#!/usr/bin/env bash
# verify-SBDEV-2095.sh
#
# Acceptance for Plan B — `SBDEV-2095-large-bol-close-decoupling-and-perf.md`.
#
# Plan B is narrowed to F3–F6 (the closeBOL-specific items Plan A's S3 doesn't address).
# F1 / F2 are owned by Plan A's helper + REQUIRES_NEW; verified in verify-260424-oms-notification.sh.
#
# Run after every implementation pass:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2095.sh

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

SVC=src/main/java/net/aim_ai/wms/service
REPO=src/main/java/net/aim_ai/wms/repo/jpa

BOL=$SVC/BillofladingService.java
ULB=$SVC/UnitloadBusinessService.java
COB_REPO=$REPO/CustomerorderBatchRepository.java
UL_REPO=$REPO/UnitloadRepository.java

echo
echo "verify-SBDEV-2095 — Plan B (F3-F6) acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# --- Plan A prerequisites (mirror, not duplicate) -----------------------------
# Plan B is blocked-by Plan A's S3 + helper. Sanity-check those before checking F3-F6.

run PRE-1 "Prereq — OmsNotificationHelper.java present" \
    test -f "$SVC/util/OmsNotificationHelper.java"
run PRE-2 "Prereq — closeBOL invokes helper with 'closeBOL' site name (Plan A S3)" \
    file_contains_ml 'OmsNotificationHelper\.deferToCommit\(\s*"closeBOL"' "$BOL"
run PRE-3 "Prereq — MessageService.createMessageInNewTransaction present" \
    file_contains 'createMessageInNewTransaction\s*\(' "$SVC/MessageService.java"

echo

# --- F3 — bolToClose correctness (Plan B §3.3) --------------------------------

run F3a "F3 — bolToClose declared as ConcurrentHashMap.newKeySet() Set" \
    file_contains 'private\s+final\s+Set<Long>\s+bolToClose\s*=\s*ConcurrentHashMap\.newKeySet\(\);' "$BOL"
run F3b "F3 — old List<Long> bolToClose declaration is gone" \
    file_not_contains 'private\s+List<Long>\s+bolToClose\s*=\s*new\s+ArrayList' "$BOL"
run F3c "F3 — entry guard uses atomic add (no inverted contains/remove branch)" \
    file_contains 'if\s*\(\s*!\s*bolToClose\.add\(' "$BOL"
run F3d "F3 — old inverted 'contains then remove' guard is gone" \
    file_not_contains 'if\s*\(bolToClose\.contains\([^)]*\)\)\s*\{[[:space:]]*[^}]*bolToClose\.remove' "$BOL"
run F3e "F3 — finally block drains bolToClose" \
    file_contains_ml 'finally\s*\{[^}]*bolToClose\.remove' "$BOL"

echo

# --- F4 — Phase 9 bulk finalize (Plan B §3.4) ---------------------------------

run F4a "F4 — CustomerorderBatchRepository.finalizeBatchesByIds present" \
    file_contains 'int\s+finalizeBatchesByIds\s*\(' "$COB_REPO"
run F4b "F4 — finalizeBatchesByIds uses NOT EXISTS guard" \
    file_contains 'NOT EXISTS' "$COB_REPO"
run F4c "F4 — closeBOL Phase 9 calls finalizeBatchesByIds" \
    file_contains 'customerorderBatchRepository\.finalizeBatchesByIds' "$BOL"
run F4d "F4 — closeBOL Phase 9 no longer has the per-batch findById loop" \
    file_not_contains 'customerorderBatchRepository\.findById\(staleBatch\.getId\(\)\)' "$BOL"

echo

# --- F5 — IN-clause chunking helper (Plan B §3.5) -----------------------------

run F5a "F5 — chunked() helper present in BillofladingService" \
    file_contains 'private\s+static\s+<T>\s+int\s+chunked\(' "$BOL"
run F5b "F5 — chunked() called for at least one bulk update" \
    file_contains_ml '\bchunked\([^;]*finalizeBatchesByIds' "$BOL"

echo

# --- F6 — bulk carrier unlink (Plan B §3.6) -----------------------------------

run F6a "F6 — UnitloadRepository.clearCarrierUnitloadByIds present" \
    file_contains 'clearCarrierUnitloadByIds\s*\(' "$UL_REPO"
run F6b "F6 — clearCarrierUnitloadByIds uses 'WHERE id IN (:ids) AND carrierunitload_id IS NOT NULL'" \
    file_contains 'WHERE\s+id\s+IN\s+\(:ids\)\s+AND\s+carrierunitload_id\s+IS\s+NOT\s+NULL' "$UL_REPO"
run F6c "F6 — UnitloadBusinessService.transferPalletTreesToLocation calls clearCarrierUnitloadByIds" \
    file_contains 'clearCarrierUnitloadByIds' "$ULB"
run F6d "F6 — old per-pallet save() loop for carrier unlink is gone" \
    file_not_contains 'pallet\.setCarrierunitloadId\(null\);[[:space:]]*unitloadRepository\.save\(pallet\);' "$ULB"

echo

# --- Targeted unit tests ------------------------------------------------------
mvn_test_passes() {
    local cls=$1
    # Don't use -q: it suppresses the [INFO] lines we need to read.
    # Trust mvn's exit code: 0 = all tests pass, non-zero = any failure.
    mvn test -Dtest="$cls" -DfailIfNoTests=false >/dev/null 2>&1
}

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T-BOL "T — BillofladingServiceUnitTest passes" mvn_test_passes BillofladingServiceUnitTest
    run T-ULB "T — UnitloadBusinessServiceUnitTest passes" mvn_test_passes UnitloadBusinessServiceUnitTest
else
    skip T-mvn "Targeted unit-test runs"  "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
