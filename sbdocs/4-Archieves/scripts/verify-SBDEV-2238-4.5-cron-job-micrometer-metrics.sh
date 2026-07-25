#!/usr/bin/env bash
# verify-SBDEV-2238-4.5-cron-job-micrometer-metrics.sh
#
# Static-verification harness for the SBDEV-2238-4.5 plan
# (Micrometer metrics for v2 cron jobs).
#
# Runs entirely from grep + file-existence assertions, plus one optional
# targeted JUnit run. No DB connection required. Pure observability plan —
# no schema or runtime-state assertions.
#
# Usage:
#   bash sbdocs/9-System/scripts/verify-SBDEV-2238-4.5-cron-job-micrometer-metrics.sh
#
# Exit codes:
#   0 = all checks passed
#   non-zero = at least one check failed (count of failures)

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
API_ROOT="$REPO_ROOT/v2/wms2-api"
SRC="$API_ROOT/src/main/java/net/aim_ai/wms"
TEST="$API_ROOT/src/test/java/net/aim_ai/wms"
RES="$API_ROOT/src/main/resources"

POM="$API_ROOT/pom.xml"
APP_PROPS="$RES/application.properties"
JOBMETRICS="$SRC/schedulejob/JobMetrics.java"

JOB_ORDER_RELEASE="$SRC/schedulejob/OrderReleaseJob.java"
JOB_REPLENISH="$SRC/schedulejob/ReplenishOrderJob.java"
JOB_STOCK_EXPORT="$SRC/schedulejob/StockSummaryExportJob.java"
JOB_CLEANUP_MSGS="$SRC/schedulejob/CleanUpOldMessagesJob.java"
JOB_RELEASE_PICKING="$SRC/schedulejob/ReleaseExpiredPickingOrdersFromUserJob.java"

TEST_ORDER_RELEASE="$TEST/unit/schedulejob/OrderReleaseJobMetricsUnitTest.java"
TEST_REPLENISH="$TEST/unit/schedulejob/ReplenishOrderJobMetricsUnitTest.java"
TEST_STOCK_EXPORT="$TEST/unit/schedulejob/StockSummaryExportJobMetricsUnitTest.java"
TEST_CLEANUP_MSGS="$TEST/unit/schedulejob/CleanUpOldMessagesJobMetricsUnitTest.java"
TEST_RELEASE_PICKING="$TEST/unit/schedulejob/ReleaseExpiredPickingOrdersFromUserJobMetricsUnitTest.java"

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

# Run a targeted JUnit class and require BUILD SUCCESS.
mvn_test_passes() {
    local test_class=$1
    (cd "$API_ROOT" && mvn test -Dtest="$test_class" -DfailIfNoTests=false -q 2>&1) \
        | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0"
}

echo
echo "verify-SBDEV-2238-4.5 — running acceptance checks"
echo "  REPO_ROOT=$REPO_ROOT"
echo "  API_ROOT=$API_ROOT"
echo

# --- 0. Source-tree sanity ------------------------------------------------

section "0. Source-tree sanity — files we will assert against must exist"

check "Sanity: pom.xml present" \
    test -f "$POM"
check "Sanity: application.properties present" \
    test -f "$APP_PROPS"
check "Sanity: OrderReleaseJob.java present" \
    test -f "$JOB_ORDER_RELEASE"
check "Sanity: ReplenishOrderJob.java present" \
    test -f "$JOB_REPLENISH"
check "Sanity: StockSummaryExportJob.java present" \
    test -f "$JOB_STOCK_EXPORT"
check "Sanity: CleanUpOldMessagesJob.java present" \
    test -f "$JOB_CLEANUP_MSGS"
check "Sanity: ReleaseExpiredPickingOrdersFromUserJob.java present" \
    test -f "$JOB_RELEASE_PICKING"

# --- 1. Infrastructure changes -------------------------------------------

section "1. Infrastructure — Prometheus registry + actuator exposure"

check "Infra: pom.xml declares micrometer-registry-prometheus dependency" \
    grep -qE "<artifactId>[[:space:]]*micrometer-registry-prometheus[[:space:]]*</artifactId>" "$POM"

check "Infra: application.properties includes prometheus in exposure list" \
    grep -qE "^management\.endpoints\.web\.exposure\.include[[:space:]]*=.*\bprometheus\b" "$APP_PROPS"

# --- 2. Helper class ------------------------------------------------------

section "2. JobMetrics helper class"

check "Helper: JobMetrics.java exists" \
    test -f "$JOBMETRICS"

check "Helper: JobMetrics declares MeterRegistry field/parameter" \
    grep -qE "MeterRegistry" "$JOBMETRICS"

check "Helper: JobMetrics registers last_run_epoch_seconds gauge" \
    grep -qE 'last_run_epoch_seconds' "$JOBMETRICS"

check "Helper: JobMetrics registers last_success_epoch_seconds gauge" \
    grep -qE 'last_success_epoch_seconds' "$JOBMETRICS"

check "Helper: JobMetrics exposes skippedLockBusy()" \
    grep -qE 'skippedLockBusy[[:space:]]*\(' "$JOBMETRICS"

check "Helper: JobMetrics exposes tenantSuccess()" \
    grep -qE 'tenantSuccess[[:space:]]*\(' "$JOBMETRICS"

check "Helper: JobMetrics exposes tenantFailure()" \
    grep -qE 'tenantFailure[[:space:]]*\(' "$JOBMETRICS"

check "Helper: JobMetrics uses wms2.cron. metric prefix" \
    grep -qE 'wms2\.cron\.' "$JOBMETRICS"

# --- 3. Per-job wiring ---------------------------------------------------

section "3. Per-job wiring — each of the 5 jobs references JobMetrics"

# OrderReleaseJob
check "Job #1 OrderReleaseJob: references jobMetrics.skippedLockBusy()" \
    grep -qE 'jobMetrics\.skippedLockBusy\(' "$JOB_ORDER_RELEASE"
check "Job #1 OrderReleaseJob: references jobMetrics.tenantSuccess(" \
    grep -qE 'jobMetrics\.tenantSuccess\(' "$JOB_ORDER_RELEASE"
check "Job #1 OrderReleaseJob: references jobMetrics.tenantFailure(" \
    grep -qE 'jobMetrics\.tenantFailure\(' "$JOB_ORDER_RELEASE"

# ReplenishOrderJob
check "Job #2 ReplenishOrderJob: references jobMetrics.skippedLockBusy()" \
    grep -qE 'jobMetrics\.skippedLockBusy\(' "$JOB_REPLENISH"
check "Job #2 ReplenishOrderJob: references jobMetrics.tenantSuccess(" \
    grep -qE 'jobMetrics\.tenantSuccess\(' "$JOB_REPLENISH"
check "Job #2 ReplenishOrderJob: references jobMetrics.tenantFailure(" \
    grep -qE 'jobMetrics\.tenantFailure\(' "$JOB_REPLENISH"

# StockSummaryExportJob
check "Job #3 StockSummaryExportJob: references jobMetrics.skippedLockBusy()" \
    grep -qE 'jobMetrics\.skippedLockBusy\(' "$JOB_STOCK_EXPORT"
check "Job #3 StockSummaryExportJob: references jobMetrics.tenantSuccess(" \
    grep -qE 'jobMetrics\.tenantSuccess\(' "$JOB_STOCK_EXPORT"
check "Job #3 StockSummaryExportJob: references jobMetrics.tenantFailure(" \
    grep -qE 'jobMetrics\.tenantFailure\(' "$JOB_STOCK_EXPORT"

# CleanUpOldMessagesJob
check "Job #4 CleanUpOldMessagesJob: references jobMetrics.skippedLockBusy()" \
    grep -qE 'jobMetrics\.skippedLockBusy\(' "$JOB_CLEANUP_MSGS"
check "Job #4 CleanUpOldMessagesJob: references jobMetrics.tenantSuccess(" \
    grep -qE 'jobMetrics\.tenantSuccess\(' "$JOB_CLEANUP_MSGS"
check "Job #4 CleanUpOldMessagesJob: references jobMetrics.tenantFailure(" \
    grep -qE 'jobMetrics\.tenantFailure\(' "$JOB_CLEANUP_MSGS"

# ReleaseExpiredPickingOrdersFromUserJob
check "Job #5 ReleaseExpiredPickingOrdersFromUserJob: references jobMetrics.skippedLockBusy()" \
    grep -qE 'jobMetrics\.skippedLockBusy\(' "$JOB_RELEASE_PICKING"
check "Job #5 ReleaseExpiredPickingOrdersFromUserJob: references jobMetrics.tenantSuccess(" \
    grep -qE 'jobMetrics\.tenantSuccess\(' "$JOB_RELEASE_PICKING"
check "Job #5 ReleaseExpiredPickingOrdersFromUserJob: references jobMetrics.tenantFailure(" \
    grep -qE 'jobMetrics\.tenantFailure\(' "$JOB_RELEASE_PICKING"

# --- 4. Job-specific extras ----------------------------------------------

section "4. Job-specific extras"

check "ReplenishOrderJob: references skippedJvmBusy (JVM-local AtomicBoolean guard)" \
    grep -qE 'skippedJvmBusy' "$JOB_REPLENISH"

check "ReplenishOrderJob: references suboperation_rows OR suboperationRows OR replenishSubOpRows" \
    grep -qE 'suboperation_rows|suboperationRows|replenishSubOpRows' "$JOB_REPLENISH"

check "StockSummaryExportJob: references consumer_timeout OR consumerTimeout" \
    grep -qE 'consumer_timeout|consumerTimeout' "$JOB_STOCK_EXPORT"

# Cross-check: JobMetrics helper exposes the extras
check "JobMetrics helper: declares replenishSubOpRows (or suboperation_rows tag)" \
    grep -qE 'replenishSubOpRows|suboperation_rows' "$JOBMETRICS"

check "JobMetrics helper: declares consumerTimeout (or consumer_timeout tag)" \
    grep -qE 'consumerTimeout|consumer_timeout' "$JOBMETRICS"

# --- 5. Unit tests --------------------------------------------------------

section "5. Unit tests — per-job MetricsUnitTest class exists"

check "Test: OrderReleaseJobMetricsUnitTest present" \
    test -f "$TEST_ORDER_RELEASE"
check "Test: ReplenishOrderJobMetricsUnitTest present" \
    test -f "$TEST_REPLENISH"
check "Test: StockSummaryExportJobMetricsUnitTest present" \
    test -f "$TEST_STOCK_EXPORT"
check "Test: CleanUpOldMessagesJobMetricsUnitTest present" \
    test -f "$TEST_CLEANUP_MSGS"
check "Test: ReleaseExpiredPickingOrdersFromUserJobMetricsUnitTest present" \
    test -f "$TEST_RELEASE_PICKING"

# Sanity: tests use SimpleMeterRegistry (no Prometheus registry needed in tests)
if [ -f "$TEST_ORDER_RELEASE" ]; then
    check "Test: OrderReleaseJobMetricsUnitTest uses SimpleMeterRegistry" \
        grep -qE 'SimpleMeterRegistry' "$TEST_ORDER_RELEASE"
else
    skip "Test: OrderReleaseJobMetricsUnitTest uses SimpleMeterRegistry" "test file not present"
fi

if [ -f "$TEST_REPLENISH" ]; then
    check "Test: ReplenishOrderJobMetricsUnitTest covers skipped_jvm_busy" \
        grep -qE 'skipped_jvm_busy|skippedJvmBusy|jvmBusy' "$TEST_REPLENISH"
    check "Test: ReplenishOrderJobMetricsUnitTest covers suboperation rows" \
        grep -qE 'suboperation_rows|suboperationRows|sub_op|subOp' "$TEST_REPLENISH"
else
    skip "Test: ReplenishOrderJobMetricsUnitTest sub-op coverage" "test file not present"
fi

if [ -f "$TEST_STOCK_EXPORT" ]; then
    check "Test: StockSummaryExportJobMetricsUnitTest covers consumer timeout" \
        grep -qE 'consumer_timeout|consumerTimeout' "$TEST_STOCK_EXPORT"
else
    skip "Test: StockSummaryExportJobMetricsUnitTest consumer_timeout coverage" "test file not present"
fi

# --- 6. Behavioural — mvn test (optional) --------------------------------

section "6. Behavioural — targeted unit tests pass (optional)"

if command -v mvn >/dev/null 2>&1 && test -d "$API_ROOT"; then
    if [ -f "$TEST_ORDER_RELEASE" ]; then
        check "mvn test -Dtest=OrderReleaseJobMetricsUnitTest passes" \
            mvn_test_passes OrderReleaseJobMetricsUnitTest
    else
        skip "mvn test -Dtest=OrderReleaseJobMetricsUnitTest" "test file not present yet"
    fi
    if [ -f "$TEST_REPLENISH" ]; then
        check "mvn test -Dtest=ReplenishOrderJobMetricsUnitTest passes" \
            mvn_test_passes ReplenishOrderJobMetricsUnitTest
    else
        skip "mvn test -Dtest=ReplenishOrderJobMetricsUnitTest" "test file not present yet"
    fi
    if [ -f "$TEST_STOCK_EXPORT" ]; then
        check "mvn test -Dtest=StockSummaryExportJobMetricsUnitTest passes" \
            mvn_test_passes StockSummaryExportJobMetricsUnitTest
    else
        skip "mvn test -Dtest=StockSummaryExportJobMetricsUnitTest" "test file not present yet"
    fi
    if [ -f "$TEST_CLEANUP_MSGS" ]; then
        check "mvn test -Dtest=CleanUpOldMessagesJobMetricsUnitTest passes" \
            mvn_test_passes CleanUpOldMessagesJobMetricsUnitTest
    else
        skip "mvn test -Dtest=CleanUpOldMessagesJobMetricsUnitTest" "test file not present yet"
    fi
    if [ -f "$TEST_RELEASE_PICKING" ]; then
        check "mvn test -Dtest=ReleaseExpiredPickingOrdersFromUserJobMetricsUnitTest passes" \
            mvn_test_passes ReleaseExpiredPickingOrdersFromUserJobMetricsUnitTest
    else
        skip "mvn test -Dtest=ReleaseExpiredPickingOrdersFromUserJobMetricsUnitTest" "test file not present yet"
    fi
else
    skip "behavioural mvn test runs" "mvn not on PATH or API_ROOT missing"
fi

# --- Summary -------------------------------------------------------------

echo
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "SKIP: $SKIP"
exit "$FAIL"
