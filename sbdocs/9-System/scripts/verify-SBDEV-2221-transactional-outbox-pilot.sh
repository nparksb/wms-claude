#!/usr/bin/env bash
# verify-SBDEV-2221-transactional-outbox-pilot.sh
#
# Static-verification harness for the SBDEV-2221 Transactional Outbox Pilot plan.
# All checks are grep/file-existence based and run from the repo root. No DB
# connection required — DB-side verification happens in the integration test
# suite and the manual smoke step (§8 of the plan).
#
# Usage:
#   bash sbdocs/9-System/scripts/verify-SBDEV-2221-transactional-outbox-pilot.sh
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
PROPS="$API_ROOT/src/main/resources/application.properties"
DEV_PROPS="$API_ROOT/src/main/resources/application_dev.properties"
DOCS_ARCH="$REPO_ROOT/sbdocs/3-Resources/architecture"

FAIL=0
PASS=0

check()    { local name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "PASS  $name"; PASS=$((PASS+1)); else echo "FAIL  $name"; FAIL=$((FAIL+1)); fi; }
checkneg() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "FAIL  $name"; FAIL=$((FAIL+1)); else echo "PASS  $name"; PASS=$((PASS+1)); fi; }
section()  { echo; echo "=== $1 ==="; }

section "1. Flyway migration"
check "V1.1.16__add_outbox_message.sql exists" \
  test -f "$MIG/V1.1.16__add_outbox_message.sql"
check "No duplicate V1.1.16 migration" \
  bash -c 'count=$(ls "'"$MIG"'"/V1.1.16__*.sql 2>/dev/null | wc -l); [ "$count" -eq 1 ]'
check "Migration creates outbox_message table" \
  grep -q "CREATE TABLE IF NOT EXISTS outbox_message" "$MIG/V1.1.16__add_outbox_message.sql"
check "Migration adds partial dispatch index" \
  grep -q "index_outbox_message_dispatch" "$MIG/V1.1.16__add_outbox_message.sql"
check "Migration adds idempotency_key UNIQUE constraint" \
  grep -q "uk_outbox_message_idempotency_key" "$MIG/V1.1.16__add_outbox_message.sql"
check "Migration adds status CHECK constraint" \
  grep -q "ck_outbox_message_status" "$MIG/V1.1.16__add_outbox_message.sql"

section "2. JPA entity"
check "OutboxMessage entity exists" \
  test -f "$SRC/model/OutboxMessage.java"
check "OutboxMessage uses jakarta.persistence" \
  grep -q "import jakarta.persistence" "$SRC/model/OutboxMessage.java"
checkneg "OutboxMessage does NOT use javax.persistence" \
  grep -q "import javax.persistence" "$SRC/model/OutboxMessage.java"
checkneg "OutboxMessage has NO @ManyToOne" \
  grep -q "@ManyToOne" "$SRC/model/OutboxMessage.java"
check "OutboxMessage uses @CreatedDate / @LastModifiedDate" \
  bash -c 'grep -q "@CreatedDate" "'"$SRC"'/model/OutboxMessage.java" && grep -q "@LastModifiedDate" "'"$SRC"'/model/OutboxMessage.java"'
check "OutboxMessage has @Version for optimistic locking" \
  grep -q "@Version" "$SRC/model/OutboxMessage.java"
check "OutboxMessage declares Status enum with all 5 values" \
  bash -c 'grep -q "PENDING" "'"$SRC"'/model/OutboxMessage.java" && grep -q "SENT" "'"$SRC"'/model/OutboxMessage.java" && grep -q "FAILED_RETRY" "'"$SRC"'/model/OutboxMessage.java" && grep -q "FAILED_TERMINAL" "'"$SRC"'/model/OutboxMessage.java" && grep -q "IN_FLIGHT" "'"$SRC"'/model/OutboxMessage.java"'

section "3. Repository"
check "OutboxMessageRepository exists" \
  test -f "$SRC/repo/jpa/OutboxMessageRepository.java"
check "findAndClaimPending declared (claim-then-release Phase 1)" \
  grep -q "findAndClaimPending" "$SRC/repo/jpa/OutboxMessageRepository.java"
check "reclaimStaleInFlight declared (claim-then-release Phase 0)" \
  grep -q "reclaimStaleInFlight" "$SRC/repo/jpa/OutboxMessageRepository.java"
check "Repo uses FOR UPDATE SKIP LOCKED" \
  grep -q "FOR UPDATE SKIP LOCKED" "$SRC/repo/jpa/OutboxMessageRepository.java"
check "Repo claim query flips status to IN_FLIGHT" \
  grep -q "IN_FLIGHT" "$SRC/repo/jpa/OutboxMessageRepository.java"
checkneg "Legacy findDueForDispatch method must NOT exist (HTTP-in-tx antipattern)" \
  grep -q "findDueForDispatch" "$SRC/repo/jpa/OutboxMessageRepository.java"
check "deleteSentOlderThan declared" \
  grep -q "deleteSentOlderThan" "$SRC/repo/jpa/OutboxMessageRepository.java"

section "4. Service layer"
check "OutboxService exists" \
  test -f "$SRC/service/OutboxService.java"
check "OutboxService.enqueue uses MANDATORY propagation" \
  grep -q "Propagation.MANDATORY" "$SRC/service/OutboxService.java"
check "OutboxService transitions use REQUIRES_NEW" \
  grep -q "Propagation.REQUIRES_NEW" "$SRC/service/OutboxService.java"
check "OutboxService @Transactional uses tenantTransactionManager" \
  grep -q 'tenantTransactionManager' "$SRC/service/OutboxService.java"
check "OutboxDispatchService exists" \
  test -f "$SRC/service/job/OutboxDispatchService.java"
check "OutboxDispatchService @Transactional uses tenantTransactionManager" \
  grep -q 'tenantTransactionManager' "$SRC/service/job/OutboxDispatchService.java"
check "OutboxDispatchService sets Idempotency-Key header" \
  grep -q 'Idempotency-Key' "$SRC/service/job/OutboxDispatchService.java"
check "OutboxDispatchService emits wms2.outbox.dispatched metric" \
  grep -q 'wms2.outbox.dispatched' "$SRC/service/job/OutboxDispatchService.java"
check "Fix-G: claim-then-release calls reclaimStaleInFlight (Phase 0)" \
  grep -q 'reclaimStaleInFlight' "$SRC/service/job/OutboxDispatchService.java"
check "Fix-G: claim-then-release calls claimDueBatch / findAndClaimPending (Phase 1)" \
  bash -c 'grep -qE "claimDueBatch|findAndClaimPending" "'"$SRC"'/service/job/OutboxDispatchService.java"'
check "Fix-G: cleanupSent declares explicit Propagation" \
  bash -c 'grep -n "cleanupSent" "'"$SRC"'/service/job/OutboxDispatchService.java" | grep -q "Propagation\." || awk "/cleanupSent/{found=1} found && /Propagation\\./{print; exit}" "'"$SRC"'/service/job/OutboxDispatchService.java" | grep -q "Propagation\\."'
check "Fix-G: dispatchBatch method exists" \
  grep -q 'public void dispatchBatch' "$SRC/service/job/OutboxDispatchService.java"
checkneg "Fix-G: dispatchBatch is NOT itself @Transactional (claim-then-release entrypoint)" \
  bash -c 'awk "/@Transactional/{seen=1} seen && /public void dispatchBatch/{print; exit}" "'"$SRC"'/service/job/OutboxDispatchService.java" | grep -q "dispatchBatch"'
check "Fix-G: NEGATIVE — HTTP POST not inside @Transactional dispatchBatch (claim-then-release)" \
  bash -c '! awk "/@Transactional/{flag=1; next} flag && /\\}/{flag=0} flag" "'"$SRC"'/service/job/OutboxDispatchService.java" | grep -qE "(omsRestTemplate|httpRestService)\\.(exchange|post)"'
check "Fix-G: stale_inflight_recovered counter wired" \
  grep -q 'wms2.outbox.stale_inflight_recovered' "$SRC/service/job/OutboxDispatchService.java"

section "5. Scheduled job + advisory lock"
check "OutboxDispatcherJob exists" \
  test -f "$SRC/schedulejob/OutboxDispatcherJob.java"
check "Job uses @Scheduled with app.cron.outbox-dispatcher" \
  grep -q 'app.cron.outbox-dispatcher' "$SRC/schedulejob/OutboxDispatcherJob.java"
check "Job acquires AdvisoryLock OUTBOX_DISPATCHER" \
  grep -q 'JobLockId.OUTBOX_DISPATCHER' "$SRC/schedulejob/OutboxDispatcherJob.java"
check "Job iterates tenants via TenantContext" \
  bash -c 'grep -q "TenantContext.setCurrentTenant" "'"$SRC"'/schedulejob/OutboxDispatcherJob.java" && grep -q "TenantContext.clear" "'"$SRC"'/schedulejob/OutboxDispatcherJob.java"'
check "Job calls cleanupSent inside the lock window" \
  grep -q 'cleanupSent' "$SRC/schedulejob/OutboxDispatcherJob.java"
check "AdvisoryLockService declares OUTBOX_DISPATCHER = 100008L" \
  grep -q 'OUTBOX_DISPATCHER\s*=\s*100008L' "$SRC/service/AdvisoryLockService.java"

section "6. Pilot call site rewrite (BillofladingService.closeBOL)"
check "BillofladingService calls outboxService.enqueue" \
  grep -q 'outboxService.enqueue' "$SRC/service/BillofladingService.java"
checkneg "BillofladingService.closeBOL no longer uses omsNotificationService.sendAfterCommit for ORDER_BATCH_SHIPPED" \
  bash -c 'awk "/closeBOL/,/^    }/" "'"$SRC"'/service/BillofladingService.java" | grep -q "omsNotificationService.sendAfterCommit"'
check "BillofladingService.closeBOL increments wms2.outbox.serialize_failed counter on IOException (no rethrow)" \
  grep -q 'wms2.outbox.serialize_failed' "$SRC/service/BillofladingService.java"
checkneg "BillofladingService.closeBOL does NOT rethrow IOException as BusinessException (operator-driven action; preserve BOL state)" \
  bash -c 'awk "/closeBOL/,/^    }/" "'"$SRC"'/service/BillofladingService.java" | grep -q "throw new BusinessException"'

section "6b. Service-layer guards"
check "OutboxService.enqueue validates idempotencyKey length (<=64) with IllegalArgumentException" \
  bash -c 'grep -q "IllegalArgumentException" "'"$SRC"'/service/OutboxService.java" && grep -q "idempotencyKey\|idempotency_key\|getIdempotencyKey" "'"$SRC"'/service/OutboxService.java"'

section "7. Properties"
check "app.cron.outbox-dispatcher defined" \
  grep -q '^app.cron.outbox-dispatcher' "$PROPS"
check "app.outbox.dispatcher.batch-size defined" \
  grep -q '^app.outbox.dispatcher.batch-size' "$PROPS"
check "app.outbox.dispatcher.batch-size default is conservative (=10, bounds tick under slow OMS)" \
  grep -q '^app.outbox.dispatcher.batch-size=10$' "$PROPS"
check "app.outbox.dispatcher.max-attempts defined" \
  grep -q '^app.outbox.dispatcher.max-attempts' "$PROPS"
check "app.outbox.dispatcher.retention-days defined" \
  grep -q '^app.outbox.dispatcher.retention-days' "$PROPS"

section "8. Tests"
check "OutboxServiceUnitTest exists" \
  test -f "$TEST/unit/service/OutboxServiceUnitTest.java"
check "OutboxDispatcherJobUnitTest exists" \
  test -f "$TEST/unit/schedulejob/OutboxDispatcherJobUnitTest.java"
check "OutboxDispatcherIntegrationTest exists" \
  test -f "$TEST/integration/OutboxDispatcherIntegrationTest.java"
check "BillofladingOutboxIntegrationTest exists" \
  test -f "$TEST/integration/BillofladingOutboxIntegrationTest.java"
check "Integration test is annotated @Testcontainers (Postgres required)" \
  grep -q '@Testcontainers' "$TEST/integration/OutboxDispatcherIntegrationTest.java"

section "9. Documentation"
check "wms2-oms-integration-map.md mentions SBDEV-2221" \
  grep -q 'SBDEV-2221' "$DOCS_ARCH/wms2-oms-integration-map.md"
check "wms2-scheduled-jobs-catalog.md mentions OutboxDispatcherJob" \
  grep -q 'OutboxDispatcherJob' "$DOCS_ARCH/wms2-scheduled-jobs-catalog.md"
check "v2/wms2-api/CLAUDE.md mentions Transactional Outbox" \
  grep -q 'Transactional Outbox' "$API_ROOT/CLAUDE.md"

section "10. v2 constraint checklist (cross-cutting greps)"
checkneg "No bare @Transactional in OutboxService (must specify tenantTransactionManager)" \
  bash -c 'grep -E "@Transactional\b" "'"$SRC"'/service/OutboxService.java" | grep -vE "tenantTransactionManager"'
checkneg "No bare @Transactional in OutboxDispatchService (must specify tenantTransactionManager)" \
  bash -c 'grep -E "@Transactional\b" "'"$SRC"'/service/job/OutboxDispatchService.java" | grep -vE "tenantTransactionManager"'

echo
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
exit "$FAIL"
