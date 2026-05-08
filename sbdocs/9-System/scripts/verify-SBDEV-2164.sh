#!/usr/bin/env bash
# verify-SBDEV-2164.sh
# Verify: WMS Cron Cleanup for Stale Club Batches (SBDEV-2164)
# Run from owl/ root: bash sbdocs/9-System/scripts/verify-SBDEV-2164.sh
# Exit 0 = all pass. Exit 1 = one or more failures.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SVC="$ROOT/v1/wms-api/src/main/java/net/aim_ai/wms/service"
JOB="$ROOT/v1/wms-api/src/main/java/net/aim_ai/wms/schedulejob"
JOB_SVC="$ROOT/v1/wms-api/src/main/java/net/aim_ai/wms/service/job"
REPO="$ROOT/v1/wms-api/src/main/java/net/aim_ai/wms/repo/jpa"
TEST_SVC="$ROOT/v1/wms-api/src/test/java/net/aim_ai/wms/unit/service"

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
file_contains_ml() { perl -0777 -ne "exit(/$1/ms ? 0 : 1)" "$2" 2>/dev/null; }

echo "=== verify-SBDEV-2164  WMS: Cron Cleanup for Stale Club Batches ==="
echo

# ---------------------------------------------------------------------------
# F1 — StaleClubBatchCleanupJobService: transaction guard comment
# ---------------------------------------------------------------------------
JSVC="$JOB_SVC/StaleClubBatchCleanupJobService.java"

run F1a "Job service — new file exists" \
    test -f "$JSVC"

run F1b "Job service — MAX_CANDIDATES_PER_RUN cap constant present" \
    file_contains 'MAX_CANDIDATES_PER_RUN' "$JSVC"

run F1c "Job service — @Transactional NOT added to cleanupStaleBatches (per-batch isolation guard)" \
    bash -c '! grep -E "@Transactional" '"$JSVC"' | grep -q "cleanupStaleBatches\|class StaleClub"'

run F1d "Job service — NEGATIVE: no bare @Transactional on the class or cleanupStaleBatches method" \
    bash -c '! grep -qE "^\s*@Transactional" '"$JSVC"' 2>/dev/null'

# ---------------------------------------------------------------------------
# F2 — Per-batch exception isolation (MAJOR-2)
# ---------------------------------------------------------------------------
run F2a "Exception isolation — try/catch(Exception) per loop iteration present" \
    file_contains 'catch\s*\(\s*Exception' "$JSVC"

run F2b "Exception isolation — failed counter incremented on catch" \
    file_contains 'failed\+\+' "$JSVC"

run F2c "Exception isolation — summary log reports both corrected and failed counts" \
    file_contains 'corrected.*failed|failed.*corrected' "$JSVC"

run F2d "Exception isolation — catch logs warn (not swallows silently)" \
    file_contains 'LOG\.warn.*failed to finalize|LOG\.warn.*skipping' "$JSVC"

# ---------------------------------------------------------------------------
# F3 — Blast-radius cap / LIMIT on query (MAJOR-3)
# ---------------------------------------------------------------------------
BREPO="$REPO/CustomerorderBatchRepository.java"

run F3a "Repository — findStaleClubBatchIds method exists" \
    file_contains 'findStaleClubBatchIds' "$BREPO"

run F3b "Repository — LIMIT param in native query" \
    file_contains 'LIMIT[ \t]+:batchSize|LIMIT[ \t]+[0-9]|LIMIT :batchSize' "$BREPO"

run F3c "Job service — batchSize/cap passed to findStaleClubBatchIds call" \
    file_contains_ml 'findStaleClubBatchIds[\s\S]{0,200}MAX_CANDIDATES' "$JSVC"

run F3d "Job service — cap-hit warning logged when list is at limit" \
    file_contains 'size.*>=.*MAX_CANDIDATES|>=.*MAX_CANDIDATES_PER_RUN' "$JSVC"

# ---------------------------------------------------------------------------
# F4 — Transaction explanation comment (MAJOR-1)
# ---------------------------------------------------------------------------
run F4a "Transaction comment — explains why @Transactional must NOT be added" \
    file_contains 'Do NOT add @Transactional|Do not add @Transactional\|not add.*@Transactional' "$JSVC"

run F4b "Transaction comment — references class-level @Transactional on CustomerorderBatchService" \
    file_contains 'class-level @Transactional|CustomerorderBatchService.*@Transactional|@Transactional.*CustomerorderBatchService' "$JSVC"

# ---------------------------------------------------------------------------
# F5 — Missing tests for exception isolation and activation flag (MAJOR-4)
# ---------------------------------------------------------------------------
TEST_FILE="$TEST_SVC/job/StaleClubBatchCleanupJobServiceUnitTest.java"

run F5a "Test file — exists" \
    test -f "$TEST_FILE"

run F5b "Test — whenOneBatchThrowsException_remainingBatchesStillProcessed" \
    file_contains 'Throws.*remaining|remaining.*Processed|OneThrows|throwsException.*remaining|exception.*remaining' "$TEST_FILE"

run F5c "Test — whenActivationFlagDisabled / whenSyspropDeactivated" \
    file_contains 'Disabled|Deactivated|disabled|deactivated|FlagFalse|flagFalse|NotActivated' "$TEST_FILE"

run F5d "Test — whenNoStaleBatches_thenNothingFinalized" \
    file_contains 'NoStaleBatches|noStale|emptyList|EmptyList|nothingFinalized' "$TEST_FILE"

# ---------------------------------------------------------------------------
# F6 — WmsConstants sysprop keys (MAJOR-5 / completeness)
# ---------------------------------------------------------------------------
CONST="$SVC/WmsConstants.java"

run F6a "WmsConstants — STALE_CLUB_BATCH_CLEANUP_ACTIVATED_KEY defined" \
    file_contains 'STALE_CLUB_BATCH_CLEANUP_ACTIVATED_KEY' "$CONST"

run F6b "WmsConstants — STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR_KEY defined" \
    file_contains 'STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR_KEY' "$CONST"

run F6c "WmsConstants — STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE_KEY defined" \
    file_contains 'STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE_KEY' "$CONST"

# ---------------------------------------------------------------------------
# F7 — SchedulingConfiguration wired up
# ---------------------------------------------------------------------------
SCHED="$JOB/SchedulingConfiguration.java"

run F7a "SchedulingConfiguration — staleClubBatchCleanupJob injected" \
    file_contains 'staleClubBatchCleanupJob|StaleClubBatchCleanupJob' "$SCHED"

run F7b "SchedulingConfiguration — staleClubBatchCleanup() method added" \
    file_contains 'staleClubBatchCleanup\(' "$SCHED"

# ---------------------------------------------------------------------------
# F8 — Cron job shell file
# ---------------------------------------------------------------------------
CRON_JOB="$JOB/StaleClubBatchCleanupJob.java"

run F8a "Cron shell — StaleClubBatchCleanupJob.java exists" \
    test -f "$CRON_JOB"

run F8b "Cron shell — activation sysprop key referenced" \
    file_contains 'STALE_CLUB_BATCH_CLEANUP_ACTIVATED_KEY' "$CRON_JOB"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
TOTAL=$((PASS + FAIL))
echo "Result: $PASS pass, $FAIL fail (of $TOTAL checks)"
[ "$FAIL" -eq 0 ]
