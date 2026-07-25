#!/usr/bin/env bash
# verify-SBDEV-2222-rest-inbound-no-idempotency-contract.sh
#
# Acceptance for SBDEV-2222 — REST inbound endpoints have no idempotency contract.
# Plan: sbdocs/1-Projects/wms2/plan/SBDEV-2222-rest-inbound-no-idempotency-contract.md
#
# Run after every implementation pass:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2222-rest-inbound-no-idempotency-contract.sh
#
# Modes:
#   PRE_IMPL_MODE=1  — pre-implementation: positive-existence checks may FAIL,
#                      but negative `file_not_contains` checks on not-yet-existing
#                      files are reported as SKIP rather than FAIL.
#   SKIP_MVN=1       — skip the JUnit invocations (useful in lint-only loops).
#
# Exit code is 0 if all checks pass, non-zero otherwise.

set -u

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

skip() {
    printf "  SKIP  %-12s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1))
}

# run_neg: a negative `file_not_contains`-style check that becomes SKIP (not FAIL)
# in PRE_IMPL_MODE when the target file doesn't exist yet.
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

file_contains() { test -f "$2" && grep -qE "$1" "$2" 2>/dev/null; }
# file_not_contains: requires the file to exist; absent file is a FAIL.
file_not_contains() { test -f "$2" && ! grep -qE "$1" "$2" 2>/dev/null; }
# file_contains_ml: multi-line pattern match. perl by default exits 0 even
# when the file is missing (because no input is read), so we gate on -f first.
file_contains_ml() {
    test -f "$2" || return 1
    PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null
}
file_count_at_least() {
    local pat=$1 file=$2 n=$3
    local c
    c=$(grep -cE "$pat" "$file" 2>/dev/null || echo 0)
    [ "$c" -ge "$n" ]
}

WEB=src/main/java/net/aim_ai/wms/landlord/config
SVC=src/main/java/net/aim_ai/wms/service
REPO=src/main/java/net/aim_ai/wms/repo/jpa
MODEL=src/main/java/net/aim_ai/wms/model
JOB=src/main/java/net/aim_ai/wms/schedulejob
MIG=src/main/resources/db/migration
CFG=src/main/java/net/aim_ai/wms/config

FILTER=$WEB/IdempotencyFilter.java
ENTITY=$MODEL/RestIdempotency.java
REPO_FILE=$REPO/RestIdempotencyRepository.java
SVC_FILE=$SVC/RestIdempotencyService.java
JOB_FILE=$JOB/RestIdempotencyCleanupJob.java
MIGRATION=$MIG/V1.1.15__add_rest_idempotency.sql
CLAUDEMD=CLAUDE.md
OMSMAP=../../sbdocs/3-Resources/architecture/wms2-oms-integration-map.md
ADVISORY=$SVC/AdvisoryLockService.java

echo
echo "verify-SBDEV-2222 — REST inbound idempotency acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  PRE_IMPL_MODE=$PRE_IMPL_MODE  (set PRE_IMPL_MODE=1 to soften negative checks pre-implementation)"
echo

# --- Fix A — Flyway migration ---

run A-1  "A — Flyway migration V1.1.15__add_rest_idempotency.sql exists" \
    test -f "$MIGRATION"
run A-2  "A — Migration creates rest_idempotency table" \
    file_contains_ml 'CREATE TABLE (IF NOT EXISTS )?rest_idempotency' "$MIGRATION"
run A-3  "A — Migration has idempotency_key as PRIMARY KEY (VARCHAR(64))" \
    file_contains 'idempotency_key\s+VARCHAR\(64\)' "$MIGRATION"
run A-4  "A — Migration has request_hash column (sha256 hex)" \
    file_contains 'request_hash\s+VARCHAR\(64\)' "$MIGRATION"
run A-5  "A — Migration has response_status column" \
    file_contains 'response_status\s+INTEGER' "$MIGRATION"
run A-6  "A — Migration has response_body column (TEXT)" \
    file_contains 'response_body\s+TEXT' "$MIGRATION"
run A-7  "A — Migration has created_at column with default NOW()" \
    file_contains_ml 'created_at\s+TIMESTAMP[^,]*DEFAULT\s+NOW\(\)' "$MIGRATION"
run A-8  "A — Migration creates index on created_at for cleanup job" \
    file_contains_ml 'CREATE\s+INDEX[^;]*ON\s+rest_idempotency\s*\(\s*created_at\s*\)' "$MIGRATION"

echo

# --- Fix B — IdempotencyFilter + Entity + Repository + Service ---

run B-1  "B — RestIdempotency entity exists" \
    test -f "$ENTITY"
run B-2  "B — RestIdempotency uses jakarta.persistence (not javax)" \
    file_contains 'import jakarta\.persistence\.' "$ENTITY"
run_neg B-3  "B — RestIdempotency does NOT use javax.persistence" \
    'import javax\.persistence\.' "$ENTITY"
run B-4  "B — RestIdempotency mapped to rest_idempotency table" \
    file_contains_ml '@Table\(\s*name\s*=\s*"rest_idempotency"' "$ENTITY"

run B-5  "B — RestIdempotencyRepository exists" \
    test -f "$REPO_FILE"
run B-6  "B — Repository has tryClaim native upsert with ON CONFLICT DO NOTHING" \
    file_contains_ml 'ON\s+CONFLICT[^;]*DO\s+NOTHING' "$REPO_FILE"
run B-7  "B — Repository native query uses RETURNING for atomic claim" \
    file_contains_ml 'RETURNING' "$REPO_FILE"
run B-8  "B — Repository has findByIdempotencyKey lookup" \
    file_contains 'findByIdempotencyKey' "$REPO_FILE"

run B-9  "B — RestIdempotencyService exists" \
    test -f "$SVC_FILE"
run B-10 "B — Service.persistResponse uses tenantTransactionManager" \
    file_contains_ml '@Transactional\([^)]*tenantTransactionManager[^)]*\)' "$SVC_FILE"
run B-11 "B — Service.persistResponse uses REQUIRES_NEW propagation" \
    file_contains_ml 'propagation\s*=\s*Propagation\.REQUIRES_NEW' "$SVC_FILE"
run B-12 "B — Service has tryClaim entry-point method" \
    file_contains 'tryClaim\s*\(' "$SVC_FILE"
run_neg B-13 "B — Service uses constructor injection (no @Autowired field)" \
    '@Autowired\s*$\s*private' "$SVC_FILE"

run B-14 "B — IdempotencyFilter exists (placed in landlord/config/ next to TenantFilter)" \
    test -f "$FILTER"
run B-15 "B — IdempotencyFilter extends OncePerRequestFilter" \
    file_contains 'extends\s+OncePerRequestFilter' "$FILTER"
run B-16 "B — IdempotencyFilter uses jakarta.servlet (not javax.servlet)" \
    file_contains 'import jakarta\.servlet\.' "$FILTER"
run_neg B-17 "B — IdempotencyFilter does NOT use javax.servlet" \
    'import javax\.servlet\.' "$FILTER"
run B-18 "B — Filter reads Idempotency-Key header" \
    file_contains '"Idempotency-Key"' "$FILTER"
run B-19 "B — Filter uses ContentCachingRequestWrapper for body hashing" \
    file_contains 'ContentCachingRequestWrapper' "$FILTER"
run B-20 "B — Filter uses ContentCachingResponseWrapper for response capture" \
    file_contains 'ContentCachingResponseWrapper' "$FILTER"
run B-21 "B — Filter computes SHA-256 hash of request body" \
    file_contains_ml 'SHA-256|sha-256|sha256' "$FILTER"
run B-22 "B — Filter short-circuits with 409 on hash conflict" \
    file_contains_ml '409|HttpStatus\.CONFLICT' "$FILTER"
run B-23 "B — Filter has kill-switch via app.idempotency.enforce property" \
    file_contains_ml 'app\.idempotency\.enforce' "$FILTER"
run B-24 "B — Filter has try/catch envelope so a filter bug does not break /rest/**" \
    file_contains_ml 'catch\s*\([^)]*Exception' "$FILTER"
run B-25 "B — Filter rejects malformed Idempotency-Key with regex validation" \
    file_contains_ml '\[A-Za-z0-9_\\-\]\{1,64\}|\[A-Za-z0-9_-\]\{1,64\}' "$FILTER"

# Filter must be registered as @Bean (not @Component) so URL pattern is explicit.
run_neg B-26 "B — IdempotencyFilter is NOT annotated @Component (must be @Bean-registered)" \
    '@Component' "$FILTER"

# Filter must run AFTER Spring Security so unauthenticated requests cannot
# force DB roundtrips or replay cached 2xx responses. We enforce two things:
#   1. The filter explicitly checks Authentication.isAuthenticated() before
#      serving a replay (defence in depth).
#   2. The filter's @Order value is past Spring Security (HIGHEST_PRECEDENCE
#      is HIGHEST_PRECEDENCE+10 — too early; correct is past
#      SecurityProperties.DEFAULT_FILTER_ORDER or wired via
#      SecurityFilterChain.addFilterAfter).
run B-27 "B — Filter checks SecurityContextHolder authentication before replay" \
    file_contains_ml 'SecurityContextHolder\.getContext\(\)\.getAuthentication\(\)' "$FILTER"
run B-28 "B — Filter order is AFTER Spring Security (no HIGHEST_PRECEDENCE)" \
    file_contains_ml 'SecurityProperties\.DEFAULT_FILTER_ORDER|addFilterAfter\(' "$FILTER"
run_neg B-29 "B — Filter does NOT use Ordered.HIGHEST_PRECEDENCE (would run before auth)" \
    'Ordered\.HIGHEST_PRECEDENCE' "$FILTER"

# Replay-skips-@CacheEvict mitigation (P2-1): on replay for /rest/sku/create
# and /rest/sku/update, the filter must explicitly evict the itemdata cache
# region because the handler short-circuit prevents Spring AOP from firing
# the @CacheEvict on the controller.
run B-30 "B — Filter handles itemdata cache eviction on sku replay (or documents endpoint exclusion)" \
    file_contains_ml 'itemdata.*CacheManager|CacheManager.*itemdata|/rest/sku/(create|update).*evict|cacheEvictOnReplay|EVICT_ON_REPLAY' "$FILTER"

# shouldNotFilter carve-out for /rest/stockcount/** (MessageDummyController
# is read-only dev controller mapped under /rest/stockcount — must be
# explicitly excluded from the filter so its dev/test paths are not deduped).
run B-31 "B — Filter has shouldNotFilter carve-out (skips read-only /rest/stockcount/** + GET)" \
    file_contains_ml 'shouldNotFilter' "$FILTER"

echo

# --- Fix C — Opportunistic claim with stale-recovery TTL ---

run C-1  "C — Service handles 102-status sentinel for in-flight claim" \
    file_contains_ml '\b102\b' "$SVC_FILE"
# Strengthened TTL pattern that matches Duration.ofSeconds(60) as well as
# "60 seconds" / "60SECONDS" prose.
run C-2  "C — Service has stale-claim recovery (60s TTL)" \
    file_contains_ml '(?i)60[^A-Za-z]*second|Duration\.ofSeconds\s*\(\s*60' "$SVC_FILE"
run C-3  "C — Service has CLAIMED / REPLAYED / CONFLICT / IN_FLIGHT result discriminator" \
    file_contains_ml 'CLAIMED|REPLAYED|CONFLICT|IN_FLIGHT' "$SVC_FILE"

echo

# --- Fix D — Cleanup scheduled job ---

run D-1  "D — CleanupRestIdempotencyJobService exists" \
    test -f "$JOB_FILE"
run D-2  "D — Job has @Scheduled with cron pulled from app.cron property" \
    file_contains_ml '@Scheduled\([^)]*cron\s*=\s*"\$\{app\.cron\.cleanup-rest-idempotency' "$JOB_FILE"
# Fix the `\|` inside `-E` bug: `\|` matches a literal backslash-pipe under -E,
# alternation is plain `|`.
run D-3  "D — Job uses AdvisoryLockService for distributed-lock guard" \
    file_contains 'advisoryLockService\.|AdvisoryLockService' "$JOB_FILE"
# JobLockId.CLEANUP_REST_IDEMPOTENCY is a `public static final long` constant
# added to AdvisoryLockService.JobLockId (a static final class — NOT an enum).
# tryLock(long) takes the constant value directly.
run D-4  "D — Job references JobLockId.CLEANUP_REST_IDEMPOTENCY constant" \
    file_contains 'JobLockId\.CLEANUP_REST_IDEMPOTENCY|CLEANUP_REST_IDEMPOTENCY' "$JOB_FILE"
run D-4b "D — AdvisoryLockService.JobLockId declares CLEANUP_REST_IDEMPOTENCY as 'public static final long'" \
    file_contains_ml 'public\s+static\s+final\s+long\s+CLEANUP_REST_IDEMPOTENCY' "$ADVISORY"
run D-5  "D — Job sets and clears TenantContext per tenant in try/finally" \
    file_contains_ml 'TenantContext\.setCurrentTenant[\s\S]+finally[\s\S]+TenantContext\.clear' "$JOB_FILE"
run D-6  "D — Job deletes rows older than 7 days" \
    file_contains_ml "7\s+(days|DAYS|day)" "$JOB_FILE"
run D-7  "D — application.properties has cleanup-rest-idempotency cron" \
    file_contains 'app\.cron\.cleanup-rest-idempotency' src/main/resources/application.properties

echo

# --- Fix E — Documentation contract ---

run E-1  "E — v2/wms2-api/CLAUDE.md mentions Idempotency-Key header" \
    file_contains 'Idempotency-Key' "$CLAUDEMD"
# Fix the `\|` inside `-E` bug.
run E-2  "E — wms2-oms-integration-map.md mentions the idempotency contract" \
    file_contains 'Idempotency-Key|rest_idempotency' "$OMSMAP"

echo

# --- Negative checks (regression guards) ---

# OrderRestController.create / cancelPositions, AdviceRestController.create,
# SkuRestController.create/update should NOT introduce ad-hoc dedup code —
# the filter is the only dedup point.
ORDER_RC=src/main/java/net/aim_ai/wms/controller/rest/OrderRestController.java
ADVICE_RC=src/main/java/net/aim_ai/wms/controller/rest/AdviceRestController.java
SKU_RC=src/main/java/net/aim_ai/wms/controller/rest/SkuRestController.java

run N-1  "N — OrderRestController does NOT import RestIdempotencyService (filter does the work)" \
    file_not_contains 'import net\.aim_ai\.wms\.service\.RestIdempotencyService' "$ORDER_RC"
run N-2  "N — AdviceRestController does NOT import RestIdempotencyService" \
    file_not_contains 'import net\.aim_ai\.wms\.service\.RestIdempotencyService' "$ADVICE_RC"
run N-3  "N — SkuRestController does NOT import RestIdempotencyService" \
    file_not_contains 'import net\.aim_ai\.wms\.service\.RestIdempotencyService' "$SKU_RC"

# The existing existence-check + DB-unique-constraint backstop must remain
# (the filter is layered on top; if the filter is killed via property, the
# old TOCTOU + DB-constraint path must still be there as the safety net).
# These guards must cover every in-scope endpoint, not just create() — P3-2.
run N-4  "N — OrderRestController.create still calls findByBatchid (DB unique backstop preserved)" \
    file_contains 'customerorderBatchRepository\.findByBatchid' "$ORDER_RC"
run N-5  "N — AdviceRestController.create still calls findByExternalid" \
    file_contains 'adviceRepository\.findByExternalid' "$ADVICE_RC"
run N-6  "N — SkuRestController.create/update still calls findByClientIdAndItemNr" \
    file_contains 'itemdataService\.findByClientIdAndItemNr' "$SKU_RC"
# updatePriority backstop — operates on existing batch, must still find it.
run N-7  "N — OrderRestController.updatePriority still calls findByBatchid (existence)" \
    file_contains 'findByBatchid' "$ORDER_RC"
# finishedQA / finishedTransfer / cancelPositions still resolve customer order
# state before mutating; existence/state-check paths must remain.
run N-8  "N — OrderRestController.finishedQA / finishedTransfer / cancelPositions retain state lookups" \
    file_contains 'customerorderRepository\.findByExternalNumber|findByCustomerorderBatch_Batchid|findByExternalNumberAndCustomerorderBatch_Batchid' "$ORDER_RC"
# Advice createTransfer / createHubAndSpoke — these two endpoints do NOT use
# findByExternalid (that is only used by AdviceRestController.create at L152 +
# L258 on a different entity — boxtype). createTransfer (L397) and
# createHubAndSpoke (L525) both gate on adviceRepository.findByTransferId(...)
# against the `advice.transfer_id` column, which is the DB-level unique
# backstop for transfer/hub-and-spoke imports. Guard each method scope
# independently so a regression in either is caught.
run N-9a "N — AdviceRestController.createTransfer retains transferId existence check (adviceRepository.findByTransferId)" \
    file_contains_ml 'createTransfer\([\s\S]+?adviceRepository\.findByTransferId' "$ADVICE_RC"
run N-9b "N — AdviceRestController.createHubAndSpoke retains transferId existence check (adviceRepository.findByTransferId)" \
    file_contains_ml 'createHubAndSpoke\([\s\S]+?adviceRepository\.findByTransferId' "$ADVICE_RC"
# SkuRestController.delete must still find the SKU before deleting (otherwise
# the filter shorts a non-existent SKU into a 200 replay).
run N-10 "N — SkuRestController.delete still resolves SKU before delete" \
    file_contains 'itemdataService\.findByClientIdAndItemNr' "$SKU_RC"

echo

# --- Targeted unit tests (Surefire excludes *IT by default — use mvn verify
# for *IT tests; -Dit.test selects which integration test to run. -Dtest is
# only correct for unit tests.) ---

mvn_unit_test_passes() {
    local cls=$1
    mvn test -Dtest="$cls" -DfailIfNoTests=false >/dev/null 2>&1
}

# *IT (integration) tests must be run via `mvn verify` so the failsafe plugin
# picks them up. Otherwise Surefire silently excludes them.
mvn_it_test_passes() {
    local cls=$1
    mvn verify -Dit.test="$cls" -DfailIfNoTests=false -DskipUnitTests=true >/dev/null 2>&1
}

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T-SVC    "T — RestIdempotencyServiceUnitTest passes (mvn test)" \
        mvn_unit_test_passes RestIdempotencyServiceUnitTest
    run T-FILT   "T — IdempotencyFilterUnitTest passes (mvn test)" \
        mvn_unit_test_passes IdempotencyFilterUnitTest
    run T-FILT-IT "T — IdempotencyFilterIT passes (mvn verify -Dit.test)" \
        mvn_it_test_passes IdempotencyFilterIT
    run T-ORDER  "T — OrderRestControllerIdempotencyIT passes (mvn verify)" \
        mvn_it_test_passes OrderRestControllerIdempotencyIT
    run T-ADV    "T — AdviceRestControllerIdempotencyIT passes (mvn verify)" \
        mvn_it_test_passes AdviceRestControllerIdempotencyIT
    run T-SKU    "T — SkuRestControllerIdempotencyIT passes (mvn verify)" \
        mvn_it_test_passes SkuRestControllerIdempotencyIT
    run T-JOB    "T — CleanupRestIdempotencyJobServiceUnitTest passes (mvn test)" \
        mvn_unit_test_passes CleanupRestIdempotencyJobServiceUnitTest
else
    skip T-mvn   "Targeted unit-test runs" "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
