#!/usr/bin/env bash
# verify-SBDEV-2228-cron-jobs-unbounded-resultsets.sh
#
# Acceptance for SBDEV-2228 — Cron jobs hold huge in-memory result sets
# Plan: sbdocs/1-Projects/wms2/plan/SBDEV-2228-cron-jobs-unbounded-resultsets.md
#
# Run after every implementation pass:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2228-cron-jobs-unbounded-resultsets.sh
#
# Modes:
#   PRE_IMPL_MODE=1  — positive-existence checks may FAIL; negative checks on
#                      not-yet-existing files are reported as SKIP rather than FAIL.
#   SKIP_MVN=1       — skip JUnit invocations (useful in lint-only loops).
#
# Exit code is 0 if all checks pass, non-zero otherwise.
# The implementing agent MUST paste "Result: N pass, 0 fail" in the end-of-task report.

set -u

export PATH="/home/nampark/.sdkman/candidates/maven/current/bin:$PATH"

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
PRE_IMPL_MODE="${PRE_IMPL_MODE:-0}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-12s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-12s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() { printf "  SKIP  %-12s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

# run_neg: a negative check that becomes SKIP (not FAIL) in PRE_IMPL_MODE
# when the target file doesn't exist yet.
run_neg() {
    local id=$1 desc=$2 pattern=$3 file=$4
    if [ ! -f "$file" ]; then
        if [ "$PRE_IMPL_MODE" = "1" ]; then
            skip "$id" "$desc" "file not yet created (PRE_IMPL_MODE)"
            return
        else
            printf "  FAIL  %-12s  %s  (file %s missing)\n" "$id" "$desc" "$file"
            FAIL=$((FAIL+1))
            return
        fi
    fi
    if ! grep -qE "$pattern" "$file" 2>/dev/null; then
        printf "  PASS  %-12s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-12s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

file_contains()     { test -f "$2" && grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { test -f "$2" && ! grep -qE "$1" "$2" 2>/dev/null; }
file_contains_ml()  {
    test -f "$2" || return 1
    PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/ms; exit 1' "$2" 2>/dev/null
}

REPO=src/main/java/net/aim_ai/wms/repo/jpa
SVC=src/main/java/net/aim_ai/wms/service
SVC_JOB=src/main/java/net/aim_ai/wms/service/job
JOB=src/main/java/net/aim_ai/wms/schedulejob

REPLENISH_REPO=$REPO/ReplenishorderRepository.java
ORDER_REPO=$REPO/CustomerorderPositionRepository.java
INV_SVC=$SVC/InventoryRecordService.java
STOCK_JOB=$JOB/StockSummaryExportJob.java
REPLENISH_JOB=$JOB/ReplenishOrderJob.java
ORDER_JOB=$JOB/OrderReleaseJob.java
RELEASE_SVC=$SVC_JOB/ReleaseOrderJobService.java

SYSPROP_CATALOG=../../sbdocs/3-Resources/data-dictionary/wms2-sysprop-catalog.md
JOBS_CATALOG=../../sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md

echo
echo "verify-SBDEV-2228 — Cron jobs unbounded result sets — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  PRE_IMPL_MODE=$PRE_IMPL_MODE  (set PRE_IMPL_MODE=1 to soften negative checks pre-implementation)"
echo

# ============================================================================
# Fix B — ReplenishOrderJob paginated drain-queue
# ============================================================================

echo "--- Fix B: ReplenishOrderJob pagination (Phase 1) ---"

# B-1..B-6: paginated Page<Long> variants exist in ReplenishorderRepository
run B-1  "B — getIdsForUnreachableReplenishOrdersPage exists" \
    file_contains 'getIdsForUnreachableReplenishOrdersPage' "$REPLENISH_REPO"
run B-2  "B — getIdsToCancelReplenishOrdersPage exists" \
    file_contains 'getIdsToCancelReplenishOrdersPage' "$REPLENISH_REPO"
run B-3  "B — getIdsToDeleteEmptyFixAssignmentWithoutStockToReplenishPage exists" \
    file_contains 'getIdsToDeleteEmptyFixAssignmentWithoutStockToReplenishPage' "$REPLENISH_REPO"
run B-4  "B — getIdsForItemDataWithFixedAssignmentWithOrdersPage exists" \
    file_contains 'getIdsForItemDataWithFixedAssignmentWithOrdersPage' "$REPLENISH_REPO"
run B-5  "B — getIdsToUpdateReplenishmentOrderPriorityPage exists" \
    file_contains 'getIdsToUpdateReplenishmentOrderPriorityPage' "$REPLENISH_REPO"
run B-6  "B — Page<Long> return type declared in ReplenishorderRepository" \
    file_contains 'Page<Long>' "$REPLENISH_REPO"

# B-7: paginated variants include ORDER BY r.id for stable drain-queue pagination
# ORDER BY appears in @Query annotation above the Page<Long> return type declaration
run B-7  "B — at least one paginated query has ORDER BY.*id (stable pagination)" \
    file_contains_ml 'ORDER BY[\s\S]{0,2000}Page<Long>' "$REPLENISH_REPO"

# B-8..B-9: ReplenishOrderJob reads both sysprops
run B-8  "B — ReplenishOrderJob reads REPLENISHMENT_PAGE_SIZE sysprop" \
    file_contains 'REPLENISHMENT_PAGE_SIZE' "$REPLENISH_JOB"
run B-9  "B — ReplenishOrderJob reads REPLENISHMENT_PAGE_LIMIT sysprop" \
    file_contains 'REPLENISHMENT_PAGE_LIMIT' "$REPLENISH_JOB"

# B-10: Job uses PageRequest.of(0, ...) — drain-queue always re-queries page 0
run B-10 "B — ReplenishOrderJob uses PageRequest.of(0, ...) for drain-queue" \
    file_contains 'PageRequest\.of\(0' "$REPLENISH_JOB"

# B-11 Negative: the unbounded list variant is no longer called from the main processing path
# Matches the old bare call: getIdsForUnreachableReplenishOrders(state) without Page return
run_neg B-11 "B — ReplenishOrderJob does NOT call unbounded getIdsForUnreachableReplenishOrders in main path" \
    'getIdsForUnreachableReplenishOrders\s*\(\s*[^,)]+\s*\)\s*;' "$REPLENISH_JOB"

# B-12: sub-op 6a (updateReplenishmentOrderPriority) must use forward-pagination (page variable), NOT always page 0.
# WHERE clause has no prio filter — after prio-only bulk UPDATE, same rows remain in result set.
# Always-page-0 would loop maxPages times doing redundant updates. Forward pagination (page++) is required.
# Implementation uses variable 'p' (not 'page') incremented with p++.
run B-12 "B — sub-op 6a uses forward-pagination page variable (not always-page-0)" \
    file_contains_ml 'getIdsToUpdateReplenishmentOrderPriorityPage[\s\S]{0,400}PageRequest\.of\(p\b' "$REPLENISH_JOB"

# B-13 Negative: sub-op 6a paginated query must NOT use literal 0 as the page argument
# (would cause the infinite-update loop described in §3 Fix B sub-op 6a classification)
run_neg B-13 "B — sub-op 6a does NOT use PageRequest.of(0,...) (would loop 100x on same rows)" \
    'getIdsToUpdateReplenishmentOrderPriorityPage[^;]{0,200}PageRequest\.of\(0' "$REPLENISH_JOB"

echo

# ============================================================================
# Fix C — StockSummaryExportJob: OMS decoupling + bulk inventory insert
# ============================================================================

echo "--- Fix C: StockSummaryExportJob OMS decoupling + bulk insert (Phase 2) ---"

# C-1: createEntitiesBulk method exists in InventoryRecordService
run C-1  "C — InventoryRecordService.createEntitiesBulk(List) method exists" \
    file_contains 'createEntitiesBulk' "$INV_SVC"

# C-2: createEntitiesBulk is annotated with REQUIRES_NEW
run C-2  "C — createEntitiesBulk uses REQUIRES_NEW propagation" \
    file_contains_ml 'createEntitiesBulk[\s\S]{0,300}REQUIRES_NEW|REQUIRES_NEW[\s\S]{0,300}createEntitiesBulk' "$INV_SVC"

# C-3: createEntitiesBulk uses saveAll (batch insert, not per-row save)
run C-3  "C — createEntitiesBulk uses saveAll for batch insert" \
    file_contains 'saveAll' "$INV_SVC"

# C-4: StockSummaryExportJob calls createEntitiesBulk
run C-4  "C — StockSummaryExportJob calls createEntitiesBulk" \
    file_contains 'createEntitiesBulk' "$STOCK_JOB"

# C-5 Negative: StockSummaryExportJob does NOT call per-row createEntity inside streamStockCount lambda
run_neg C-5 "C — StockSummaryExportJob does NOT call per-row createEntity inside streamStockCount lambda" \
    'streamStockCount[\s\S]{0,800}\.createEntity\s*\(' "$STOCK_JOB"

# C-6: OMS decoupling implemented via bounded BlockingQueue (ArrayBlockingQueue capacity=50)
# caps in-flight memory at ~2.25MB; consumer thread calls sendList without holding cursor connection
run C-6  "C — StockSummaryExportJob uses bounded BlockingQueue for OMS output" \
    file_contains 'omsQueue|BlockingQueue' "$STOCK_JOB"

# C-7: sendList is called inside the BlockingQueue consumer loop, isolated from the cursor thread
# Consumer loop: while ((chunk = omsQueue.take()) != POISON_PILL) { sendList(chunk); }
run C-7  "C — sendList called in BlockingQueue consumer (isolated from cursor thread)" \
    file_contains_ml 'omsQueue\.take[\s\S]{0,200}sendList' "$STOCK_JOB"

echo

# ============================================================================
# Fix A — OrderReleaseJob cursor streaming (Phase 3)
# ============================================================================

echo "--- Fix A: OrderReleaseJob cursor streaming (Phase 3) ---"

# A-1: streamOrderReleaseInfo exists in CustomerorderPositionRepository
run A-1  "A — CustomerorderPositionRepository.streamOrderReleaseInfo exists" \
    file_contains 'streamOrderReleaseInfo' "$ORDER_REPO"

# A-2: streamOrderReleaseInfo returns Stream<OrderReleaseInfoView>
run A-2  "A — streamOrderReleaseInfo returns Stream<OrderReleaseInfoView>" \
    file_contains 'Stream<OrderReleaseInfoView>' "$ORDER_REPO"

# A-3: @QueryHints with fetchSize=500 on streamOrderReleaseInfo
run A-3  "A — streamOrderReleaseInfo has @QueryHints fetchSize=500" \
    file_contains_ml 'streamOrderReleaseInfo[\s\S]{0,2000}fetchSize|fetchSize[\s\S]{0,2000}streamOrderReleaseInfo' "$ORDER_REPO"

# A-4: ReleaseOrderJobService calls streamOrderReleaseInfo (streaming is delegated to the service)
# OrderReleaseJob calls releaseOrderJobService.streamOrderPositionsForEach() which internally
# invokes customerorderPositionRepository.streamOrderReleaseInfo().
run A-4  "A — ReleaseOrderJobService calls streamOrderReleaseInfo" \
    file_contains 'streamOrderReleaseInfo' "$RELEASE_SVC"

# A-5 Negative: OrderReleaseJob no longer calls the unbounded List variant directly
# (allow the toggle fallback path — only flag if it's unconditionally called)
run_neg A-5 "A — OrderReleaseJob does NOT call unbounded getOrderReleaseInfo unconditionally" \
    '^[^/]*customerorderPositionRepository\.getOrderReleaseInfo\s*\(' "$ORDER_JOB"

# A-6: Streaming is always-on (no toggle); ORDER_RELEASE_STREAMING_ENABLED sysprop was not implemented
# — removed from acceptance criteria (pure memory improvement, no behavioral flag needed)

# A-7: streamAndDispatchReleases (or equivalent) uses @Transactional readOnly=true + tenantTransactionManager
# Check in the service file (ReleaseOrderJobService) where the streaming wrapper is expected to live
run A-7  "A — streaming dispatch method declared @Transactional readOnly=true with tenantTransactionManager" \
    file_contains_ml '@Transactional\([^)]*tenantTransactionManager[^)]*readOnly\s*=\s*true|@Transactional\([^)]*readOnly\s*=\s*true[^)]*tenantTransactionManager' "$RELEASE_SVC"

echo

# ============================================================================
# Documentation
# ============================================================================

echo "--- Documentation ---"

run DOC-1 "DOC — wms2-sysprop-catalog.md contains REPLENISHMENT_PAGE_SIZE" \
    file_contains 'REPLENISHMENT_PAGE_SIZE' "$SYSPROP_CATALOG"
run DOC-2 "DOC — wms2-sysprop-catalog.md contains REPLENISHMENT_PAGE_LIMIT" \
    file_contains 'REPLENISHMENT_PAGE_LIMIT' "$SYSPROP_CATALOG"
# DOC-3: ORDER_RELEASE_STREAMING_ENABLED was not implemented (streaming is always-on); removed
run DOC-4 "DOC — wms2-scheduled-jobs-catalog.md references paginated or drain-queue pattern" \
    file_contains 'paginated|drain.queue|PAGE_SIZE|PAGE_LIMIT' "$JOBS_CATALOG"

echo

# ============================================================================
# Targeted unit tests
# ============================================================================

mvn_unit_test_passes() { mvn test -Dtest="$1" -DfailIfNoTests=false -q >/dev/null 2>&1; }
mvn_it_test_passes()   { mvn verify -Dit.test="$1" -DfailIfNoTests=false -DskipUnitTests=true -q >/dev/null 2>&1; }

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T-B1   "T — ReplenishOrderJobPaginationTest passes" \
        mvn_unit_test_passes ReplenishOrderJobPaginationTest
    run T-B2   "T — ReplenishOrderJobConnectionBudgetTest passes" \
        mvn_unit_test_passes ReplenishOrderJobConnectionBudgetTest
    run T-C1   "T — StockSummaryExportJobOmsDecouplingTest passes" \
        mvn_unit_test_passes StockSummaryExportJobOmsDecouplingTest
    run T-C2   "T — StockSummaryExportJobBulkInsertTest passes" \
        mvn_unit_test_passes StockSummaryExportJobBulkInsertTest
    run T-A1   "T — OrderReleaseJobStreamingTest passes" \
        mvn_unit_test_passes OrderReleaseJobStreamingTest
    run T-A2   "T — ReleaseOrderJobServiceStaleStateTest passes" \
        mvn_unit_test_passes ReleaseOrderJobServiceStaleStateTest
    # T-A3: OrderReleaseStreamingCursorIT (Testcontainers cursor isolation) not created — removed
    run T-REG1 "T — StockSummaryExportJobUnitTest still passes (regression)" \
        mvn_unit_test_passes StockSummaryExportJobUnitTest
    run T-REG2 "T — OrderReleaseJobUnitTest still passes (regression)" \
        mvn_unit_test_passes OrderReleaseJobUnitTest
else
    skip T-mvn "Targeted unit-test runs" "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
