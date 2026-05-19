#!/usr/bin/env bash
# ============================================================================
# verify-SBDEV-2238-4.6-oms-sync-reconciliation-job.sh
#
# Acceptance script for SBDEV-2238-4.6 — OMS Sync Reconciliation Job
# (daily drift detection between WMS state and OMS state for recently-mutated
#  customerorders, gated by SBDEV-2221 transactional outbox infrastructure).
#
# Sections:
#   §0 Prerequisites       — SBDEV-2221 outbox artifacts + SBDEV-2238-4.1
#                            BOL closeBOL outbox migration must be present
#   §1 New lock id          — AdvisoryLockService declares
#                            OMS_SYNC_RECONCILIATION = 100009L
#   §2 Job file + structure — OmsSyncReconciliationJob.java exists,
#                             uses the advisory lock, cross-checks outbox_message,
#                             calls OMS via HttpRestService
#   §3 Metrics              — wms2.oms.sync.drift + wms2.oms.sync.oms_unreachable
#   §4 Sysprop wiring       — application.properties contains
#                             app.cron.oms_sync_reconciliation
#   §5 Unit test            — OmsSyncReconciliationJobUnitTest.java exists
#   §6 Behavioural          — mvn test -Dtest=OmsSyncReconciliationJobUnitTest
#                             (skipped unless --with-mvn is passed)
#
# Exit code: 0 iff every check PASSes. The grand-total summary prints at end.
# ============================================================================

set -u

# ---------------------------------------------------------------------------
# Resolve repo root (this script lives at sbdocs/9-System/scripts/)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

WMS2_API_SRC="${REPO_ROOT}/v2/wms2-api/src/main/java/net/aim_ai/wms"
WMS2_API_TEST="${REPO_ROOT}/v2/wms2-api/src/test/java/net/aim_ai/wms"
WMS2_API_RES="${REPO_ROOT}/v2/wms2-api/src/main/resources"

PASS_COUNT=0
FAIL_COUNT=0
FAIL_LINES=()

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf "  \033[32mPASS\033[0m  %s\n" "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAIL_LINES+=("$1")
    printf "  \033[31mFAIL\033[0m  %s\n" "$1"
}

section() {
    printf "\n\033[1m%s\033[0m\n" "$1"
}

run() {
    # run <id> <description> <fn>
    local id="$1"
    local desc="$2"
    local fn="$3"
    printf "[%s] %s\n" "$id" "$desc"
    "$fn"
}

# ---------------------------------------------------------------------------
# §0 Prerequisites
# ---------------------------------------------------------------------------

check_prereq_outbox_message_entity() {
    local f="${WMS2_API_SRC}/model/OutboxMessage.java"
    if [ -f "$f" ]; then
        pass "OutboxMessage.java exists (SBDEV-2221)"
    else
        fail "OutboxMessage.java MISSING — SBDEV-2221 not merged (looked at ${f})"
    fi
}

check_prereq_outbox_service() {
    local f="${WMS2_API_SRC}/service/OutboxService.java"
    if [ -f "$f" ]; then
        pass "OutboxService.java exists (SBDEV-2221)"
    else
        fail "OutboxService.java MISSING — SBDEV-2221 not merged (looked at ${f})"
    fi
}

check_prereq_outbox_dispatcher() {
    local f="${WMS2_API_SRC}/schedulejob/OutboxDispatcherJob.java"
    if [ -f "$f" ]; then
        pass "OutboxDispatcherJob.java exists (SBDEV-2221)"
    else
        fail "OutboxDispatcherJob.java MISSING — SBDEV-2221 not merged (looked at ${f})"
    fi
}

check_prereq_v1116_migration() {
    local f="${WMS2_API_RES}/db/migration/V1.1.16__add_outbox_message.sql"
    if [ -f "$f" ]; then
        pass "V1.1.16__add_outbox_message.sql present (SBDEV-2221)"
    else
        fail "V1.1.16__add_outbox_message.sql MISSING — SBDEV-2221 Flyway migration not merged"
    fi
}

check_prereq_outbox_dispatcher_lockid() {
    local f="${WMS2_API_SRC}/service/AdvisoryLockService.java"
    if [ -f "$f" ] && grep -qE "OUTBOX_DISPATCHER[[:space:]]*=[[:space:]]*100008L" "$f"; then
        pass "AdvisoryLockService declares OUTBOX_DISPATCHER = 100008L (SBDEV-2221)"
    else
        fail "OUTBOX_DISPATCHER = 100008L MISSING in AdvisoryLockService.java"
    fi
}

check_prereq_bol_closebol_outbox_migration() {
    local f="${WMS2_API_SRC}/service/BillofladingService.java"
    if [ -f "$f" ] && grep -q "outboxService\.enqueue" "$f"; then
        pass "BillofladingService.closeBOL migrated to outboxService.enqueue (SBDEV-2238-4.1)"
    else
        fail "BillofladingService.java does NOT call outboxService.enqueue — SBDEV-2238-4.1 not merged"
    fi
}

# ---------------------------------------------------------------------------
# §1 New lock id — AdvisoryLockService declares OMS_SYNC_RECONCILIATION = 100009L
# ---------------------------------------------------------------------------

check_new_lockid_declared() {
    local f="${WMS2_API_SRC}/service/AdvisoryLockService.java"
    if [ -f "$f" ] && grep -qE "OMS_SYNC_RECONCILIATION[[:space:]]*=[[:space:]]*100009L" "$f"; then
        pass "AdvisoryLockService declares OMS_SYNC_RECONCILIATION = 100009L"
    else
        fail "OMS_SYNC_RECONCILIATION = 100009L NOT declared in AdvisoryLockService.java"
    fi
}

check_new_lockid_unique() {
    # Negative: 100009L must not be used by ANY other JobLockId constant.
    local f="${WMS2_API_SRC}/service/AdvisoryLockService.java"
    if [ ! -f "$f" ]; then
        fail "AdvisoryLockService.java missing — cannot verify lock-id uniqueness"
        return
    fi
    local occurrences
    occurrences=$(grep -cE "=[[:space:]]*100009L" "$f" || true)
    if [ "$occurrences" -eq 1 ]; then
        pass "Lock id 100009L is declared exactly once (no collision)"
    else
        fail "Lock id 100009L appears ${occurrences} times in AdvisoryLockService.java — expected exactly 1"
    fi
}

# ---------------------------------------------------------------------------
# §2 Job file + structure
# ---------------------------------------------------------------------------

JOB_FILE="${WMS2_API_SRC}/schedulejob/OmsSyncReconciliationJob.java"

check_job_file_exists() {
    if [ -f "$JOB_FILE" ]; then
        pass "OmsSyncReconciliationJob.java exists"
    else
        fail "OmsSyncReconciliationJob.java MISSING (expected at ${JOB_FILE})"
    fi
}

check_job_uses_advisory_lock() {
    if [ -f "$JOB_FILE" ] && grep -q "tryLock" "$JOB_FILE" && grep -q "OMS_SYNC_RECONCILIATION" "$JOB_FILE"; then
        pass "OmsSyncReconciliationJob calls tryLock(OMS_SYNC_RECONCILIATION)"
    else
        fail "OmsSyncReconciliationJob does NOT call tryLock(OMS_SYNC_RECONCILIATION) — multi-replica unsafe"
    fi
}

check_job_releases_lock() {
    # Positive: the job class must call advisoryLockService.unlock with the same lock id.
    if [ -f "$JOB_FILE" ] && grep -qE "unlock\s*\(\s*(AdvisoryLockService\.JobLockId\.)?OMS_SYNC_RECONCILIATION" "$JOB_FILE"; then
        pass "OmsSyncReconciliationJob releases advisory lock (unlock call present)"
    else
        fail "OmsSyncReconciliationJob does NOT call unlock(OMS_SYNC_RECONCILIATION) — lock will leak"
    fi
}

check_job_cross_checks_outbox() {
    # Positive: the job class must reference OutboxMessageRepository OR outbox_message.
    if [ -f "$JOB_FILE" ] && grep -qE "OutboxMessageRepository|outbox_message|OutboxMessage" "$JOB_FILE"; then
        pass "OmsSyncReconciliationJob cross-checks outbox_message before calling OMS"
    else
        fail "OmsSyncReconciliationJob does NOT reference outbox_message / OutboxMessageRepository"
    fi
}

check_job_calls_oms_http() {
    # Positive: the job class must use HttpRestService (the canonical WMS→OMS HTTP gateway).
    if [ -f "$JOB_FILE" ] && grep -q "HttpRestService\|httpRestService" "$JOB_FILE"; then
        pass "OmsSyncReconciliationJob calls OMS via HttpRestService"
    else
        fail "OmsSyncReconciliationJob does NOT call HttpRestService — cannot perform OMS GET"
    fi
}

check_job_iterates_tenants() {
    # Positive: the job must use TenantContext (per OrderReleaseJob canonical pattern).
    if [ -f "$JOB_FILE" ] && grep -qE "TenantContext\.(setCurrentTenant|clear)" "$JOB_FILE"; then
        pass "OmsSyncReconciliationJob sets and clears TenantContext (per-tenant iteration)"
    else
        fail "OmsSyncReconciliationJob does NOT manage TenantContext — wrong-tenant query risk"
    fi
}

check_job_queries_customerorder() {
    # Positive: the job must call a customerorder finder with state + updatedAt-after.
    if [ -f "$JOB_FILE" ] && grep -qE "CustomerorderRepository|customerorderRepository" "$JOB_FILE"; then
        pass "OmsSyncReconciliationJob queries CustomerorderRepository for candidate orders"
    else
        fail "OmsSyncReconciliationJob does NOT query CustomerorderRepository"
    fi
}

# ---------------------------------------------------------------------------
# §3 Metrics — drift counter and oms_unreachable counter
# ---------------------------------------------------------------------------

check_metric_drift() {
    if [ -f "$JOB_FILE" ] && grep -qE "wms2[._]oms[._]sync[._]drift" "$JOB_FILE"; then
        pass "Metric wms2.oms.sync.drift referenced in OmsSyncReconciliationJob.java"
    else
        fail "Metric wms2.oms.sync.drift NOT referenced — drift signal is invisible"
    fi
}

check_metric_oms_unreachable() {
    if [ -f "$JOB_FILE" ] && grep -qE "wms2[._]oms[._]sync[._]oms_unreachable" "$JOB_FILE"; then
        pass "Metric wms2.oms.sync.oms_unreachable referenced in OmsSyncReconciliationJob.java"
    else
        fail "Metric wms2.oms.sync.oms_unreachable NOT referenced — cannot distinguish drift from transient OMS errors"
    fi
}

check_metric_drift_has_processtype_tag() {
    # Positive: drift counter must carry a processType tag for grouping in Prometheus.
    if [ -f "$JOB_FILE" ] && grep -E "wms2[._]oms[._]sync[._]drift" "$JOB_FILE" | grep -q "processType\|ORDER_STATUS_DRIFT"; then
        pass "Drift counter carries processType tag (ORDER_STATUS_DRIFT)"
    else
        fail "Drift counter does NOT carry processType tag — Prometheus grouping degraded"
    fi
}

# ---------------------------------------------------------------------------
# §4 Sysprop wiring — application.properties contains the cron property
# ---------------------------------------------------------------------------

PROPS_FILE="${WMS2_API_RES}/application.properties"

check_props_cron_schedule() {
    if [ -f "$PROPS_FILE" ] && grep -qE "^app\.cron\.oms_sync_reconciliation[[:space:]]*=" "$PROPS_FILE"; then
        pass "application.properties declares app.cron.oms_sync_reconciliation"
    else
        fail "application.properties MISSING app.cron.oms_sync_reconciliation property"
    fi
}

check_props_window_hours() {
    if [ -f "$PROPS_FILE" ] && grep -qE "^app\.cron\.oms_sync_reconciliation_window_hours[[:space:]]*=" "$PROPS_FILE"; then
        pass "application.properties declares app.cron.oms_sync_reconciliation_window_hours"
    else
        fail "application.properties MISSING app.cron.oms_sync_reconciliation_window_hours property"
    fi
}

# ---------------------------------------------------------------------------
# §5 Unit test exists
# ---------------------------------------------------------------------------

UNIT_TEST_FILE="${WMS2_API_TEST}/unit/schedulejob/OmsSyncReconciliationJobUnitTest.java"

check_unit_test_exists() {
    if [ -f "$UNIT_TEST_FILE" ]; then
        pass "OmsSyncReconciliationJobUnitTest.java exists"
    else
        fail "OmsSyncReconciliationJobUnitTest.java MISSING (expected at ${UNIT_TEST_FILE})"
    fi
}

check_unit_test_has_drift_scenario() {
    if [ -f "$UNIT_TEST_FILE" ] && grep -qiE "drift" "$UNIT_TEST_FILE"; then
        pass "Unit test file contains drift-scenario assertions"
    else
        fail "Unit test file does NOT mention 'drift' — critical scenario missing"
    fi
}

check_unit_test_has_lockbusy_scenario() {
    if [ -f "$UNIT_TEST_FILE" ] && grep -qiE "lockBusy|tryLock.*false|skipped" "$UNIT_TEST_FILE"; then
        pass "Unit test file contains lock-busy / skipped scenario"
    else
        fail "Unit test file does NOT cover lock-busy / multi-replica scenario"
    fi
}

check_unit_test_has_unreachable_scenario() {
    if [ -f "$UNIT_TEST_FILE" ] && grep -qiE "unreachable|5xx|503|timeout" "$UNIT_TEST_FILE"; then
        pass "Unit test file covers OMS-unreachable scenario"
    else
        fail "Unit test file does NOT cover OMS-unreachable scenario"
    fi
}

# ---------------------------------------------------------------------------
# §6 Behavioural (optional, controlled by --with-mvn flag)
# ---------------------------------------------------------------------------

check_mvn_unit_test_passes() {
    if [ "${WITH_MVN:-0}" != "1" ]; then
        printf "  \033[33mSKIP\033[0m  mvn test -Dtest=OmsSyncReconciliationJobUnitTest (pass --with-mvn to run)\n"
        return
    fi
    pushd "${REPO_ROOT}/v2/wms2-api" >/dev/null || { fail "cannot cd into v2/wms2-api"; return; }
    if mvn -q test -Dtest=OmsSyncReconciliationJobUnitTest >/tmp/sbdev-2238-4.6-mvn.log 2>&1; then
        pass "mvn test -Dtest=OmsSyncReconciliationJobUnitTest succeeded"
    else
        fail "mvn test -Dtest=OmsSyncReconciliationJobUnitTest FAILED (see /tmp/sbdev-2238-4.6-mvn.log)"
    fi
    popd >/dev/null || true
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
WITH_MVN=0
for arg in "$@"; do
    case "$arg" in
        --with-mvn) WITH_MVN=1 ;;
        -h|--help)
            cat <<HELP
Usage: $(basename "$0") [--with-mvn]

  --with-mvn   Also run mvn test -Dtest=OmsSyncReconciliationJobUnitTest
               (slower; default is grep-only static checks).
HELP
            exit 0
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

printf "===============================================================\n"
printf "verify-SBDEV-2238-4.6-oms-sync-reconciliation-job.sh\n"
printf "Repo root: %s\n" "$REPO_ROOT"
printf "===============================================================\n"

section "§0 Prerequisites — SBDEV-2221 + SBDEV-2238-4.1 must be merged"
run "0.1" "OutboxMessage entity present"             check_prereq_outbox_message_entity
run "0.2" "OutboxService present"                    check_prereq_outbox_service
run "0.3" "OutboxDispatcherJob present"              check_prereq_outbox_dispatcher
run "0.4" "V1.1.16 Flyway migration present"         check_prereq_v1116_migration
run "0.5" "OUTBOX_DISPATCHER = 100008L declared"     check_prereq_outbox_dispatcher_lockid
run "0.6" "BOL closeBOL migrated to outboxService"   check_prereq_bol_closebol_outbox_migration

section "§1 New lock id — OMS_SYNC_RECONCILIATION = 100009L"
run "1.1" "Lock id 100009L declared"                 check_new_lockid_declared
run "1.2" "Lock id 100009L is unique"                check_new_lockid_unique

section "§2 Job file + structure"
run "2.1" "OmsSyncReconciliationJob.java exists"     check_job_file_exists
run "2.2" "Uses tryLock(OMS_SYNC_RECONCILIATION)"    check_job_uses_advisory_lock
run "2.3" "Releases lock in finally (unlock call)"   check_job_releases_lock
run "2.4" "Cross-checks outbox_message"              check_job_cross_checks_outbox
run "2.5" "Calls OMS via HttpRestService"            check_job_calls_oms_http
run "2.6" "Manages TenantContext per tenant"         check_job_iterates_tenants
run "2.7" "Queries CustomerorderRepository"          check_job_queries_customerorder

section "§3 Metrics"
run "3.1" "wms2.oms.sync.drift referenced"           check_metric_drift
run "3.2" "wms2.oms.sync.oms_unreachable referenced" check_metric_oms_unreachable
run "3.3" "Drift counter carries processType tag"    check_metric_drift_has_processtype_tag

section "§4 Sysprop wiring"
run "4.1" "Cron schedule property declared"          check_props_cron_schedule
run "4.2" "Window-hours property declared"           check_props_window_hours

section "§5 Unit test"
run "5.1" "Unit test file exists"                    check_unit_test_exists
run "5.2" "Covers drift scenario"                    check_unit_test_has_drift_scenario
run "5.3" "Covers lock-busy / skipped scenario"      check_unit_test_has_lockbusy_scenario
run "5.4" "Covers OMS-unreachable scenario"          check_unit_test_has_unreachable_scenario

section "§6 Behavioural (mvn — opt-in)"
run "6.1" "mvn unit test passes"                     check_mvn_unit_test_passes

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf "\n===============================================================\n"
printf "Summary: \033[32m%d pass\033[0m, \033[31m%d fail\033[0m\n" "$PASS_COUNT" "$FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
    printf "\nFailed checks:\n"
    for line in "${FAIL_LINES[@]}"; do
        printf "  - %s\n" "$line"
    done
    printf "===============================================================\n"
    exit 1
fi
printf "===============================================================\n"
exit 0
