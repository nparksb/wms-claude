#!/usr/bin/env bash
# verify-SBDEV-2220-cleanup-old-messages-batch-cap-and-tx.sh
#
# Acceptance for SBDEV-2220 — CleanUpOldMessageJobService batch-cap + transaction-boundary hardening (v2).
# Plan:  sbdocs/1-Projects/wms2/plan/SBDEV-2220-cleanup-old-messages-batch-cap-and-tx.md
#
# Run after every implementation pass:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2220-cleanup-old-messages-batch-cap-and-tx.sh
#
# Exit code is 0 if all checks pass, non-zero otherwise. The implementing
# agent's end-of-task report MUST paste this script's output before the work
# is accepted.
#
# Pre-implementation baseline expectation: 2 PRE checks PASS,
# ~37 FAIL for Fix A/B/C/D/E/F/G + test wiring + MessageRepository hardening.
#
# Set SKIP_MVN=1 to skip maven test invocations (fast static checks only).
#
# NOTE on scope: H1/H2 are scoped to MessageRepository.java only.
# Seven other repos (AdviceRepository, AdvicepositionRepository, ClientRepository,
# BillofladingRepository, BillofladingPositionRepository) carry the same pre-existing
# @Modifying+@RestResource(path=...) pattern and are explicitly out of scope for
# SBDEV-2220 (see plan §0 out-of-scope note). A codebase-wide fix belongs in a
# follow-up hygiene ticket.

# Ensure mvn is on PATH (sdkman manages the Maven installation on this machine).
# Source before set -u because sdkman-init.sh references ZSH_VERSION which is
# unbound in bash — set -u would cause an immediate exit.
# shellcheck source=/dev/null
[ -f /home/nampark/.sdkman/bin/sdkman-init.sh ] && source /home/nampark/.sdkman/bin/sdkman-init.sh

set -u

# Resolve PROJECT_ROOT relative to this script's own location so the script
# works regardless of which directory it is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../../../v2/wms2-api" 2>/dev/null && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"

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

file_contains()      { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains()  { ! grep -qE "$1" "$2" 2>/dev/null; }

# file_contains_ml: perl multi-line match. Guards with `test -f` first because
# perl -0777 -ne on a non-existent file exits 0 (reads zero records, never
# reaches exit-1) — which would silently false-pass.
file_contains_ml() {
    local pattern=$1 file=$2
    test -f "$file" || return 1
    PATTERN="$pattern" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$file" 2>/dev/null
}

mvn_test_passes() {
    local cls=$1
    local tmplog
    tmplog=$(mktemp /tmp/mvn-test-XXXXXX.log)
    if mvn test -Dtest="$cls" -DfailIfNoTests=false >"$tmplog" 2>&1 \
            && grep -qE "Tests run: [1-9]" "$tmplog"; then
        rm -f "$tmplog"; return 0
    else
        echo "  [mvn output tail for $cls:]" >&2
        tail -20 "$tmplog" >&2
        rm -f "$tmplog"; return 1
    fi
}

mvn_it_passes() {
    local cls=$1
    local tmplog
    tmplog=$(mktemp /tmp/mvn-it-XXXXXX.log)
    if mvn jacoco:prepare-agent failsafe:integration-test -Dit.test="$cls" -DfailIfNoTests=false >"$tmplog" 2>&1; then
        rm -f "$tmplog"; return 0
    else
        echo "  [mvn IT output tail for $cls:]" >&2
        tail -20 "$tmplog" >&2
        rm -f "$tmplog"; return 1
    fi
}

SVC=src/main/java/net/aim_ai/wms/service
REPO=src/main/java/net/aim_ai/wms/repo/jpa
EXC=src/main/java/net/aim_ai/wms/exceptions
RES=src/main/resources
TST_SVC_JOB=src/test/java/net/aim_ai/wms/unit/service/job
TST_INT_REPO=src/test/java/net/aim_ai/wms/integration/repository

MSGREPO=$REPO/MessageRepository.java
CLEANSVC=$SVC/job/CleanUpOldMessageJobService.java
BATCHSVC=$SVC/job/MessageCleanupBatchService.java
WMSC=$SVC/WmsConstants.java
BIZEX=$EXC/BusinessException.java
MSGS=$RES/messages_en_US.properties
CLEANSVC_TEST=$TST_SVC_JOB/CleanUpOldMessageJobServiceUnitTest.java
BATCHSVC_TEST=$TST_SVC_JOB/MessageCleanupBatchServiceUnitTest.java
MSGREPO_IT=$TST_INT_REPO/MessageRepositoryIntegrationTest.java

echo
echo "verify-SBDEV-2220 — CleanUpOldMessageJobService batch-cap + tx hardening acceptance"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# === PRE — already-done baseline (2 PASS expected before any new work) =======

# PRE-1: deleteMessages already has SOME form of LIMIT clause (pre-fix literal OR post-fix bind).
run PRE-1 "Prereq — MessageRepository.deleteMessages contains a LIMIT clause" \
    bash -c '
        grep -qE "LIMIT\s+(\"\s*\+\s*[0-9]+|:[a-zA-Z]+|[0-9]+)" "'"$MSGREPO"'" 2>/dev/null
    '

# PRE-2: CleanUpOldMessagesJob uses AdvisoryLockService.tryLock(CLEAN_UP_MESSAGES).
run PRE-2 "Prereq — CleanUpOldMessagesJob uses advisoryLockService.tryLock(CLEAN_UP_MESSAGES)" \
    bash -c '
        JOB=src/main/java/net/aim_ai/wms/schedulejob/CleanUpOldMessagesJob.java
        test -f "$JOB" || exit 1
        perl -0777 -ne "exit 0 if /advisoryLockService\.tryLock[\s\S]{0,200}?CLEAN_UP_MESSAGES/m; exit 1" "$JOB" 2>/dev/null \
        || perl -0777 -ne "exit 0 if /CLEAN_UP_MESSAGES[\s\S]{0,200}?tryLock/m; exit 1" "$JOB" 2>/dev/null
    '

echo

# === Fix A — Remove @Async from MessageRepository.deleteMessages =============
# @EnableAsync is absent from v2/wms2-api so @Async was a no-op (no async proxy
# was ever created). Removal is defensive hygiene: if @EnableAsync is ever added
# for an unrelated feature, the annotation would silently break the do-while loop.

# A1 (NEGATIVE): @Async annotation no longer present in MessageRepository.java.
run A1 "Fix A — MessageRepository.java contains no @Async annotation" \
    file_not_contains '@Async' "$MSGREPO"

# A2 (NEGATIVE): Async import also removed (no dead import).
run A2 "Fix A — MessageRepository.java does not import org.springframework.scheduling.annotation.Async" \
    file_not_contains 'import\s+org\.springframework\.scheduling\.annotation\.Async' "$MSGREPO"

echo

# === Fix B — @Transactional moved from repo to service layer =================
# Bare @Transactional on @Modifying repo methods overrides the implicit
# tenantTransactionManager inheritance from @EnableJpaRepositories and binds
# to landlordTransactionManager (@Primary). Strip from repo; put explicit
# tenantTransactionManager+REQUIRES_NEW on the new MessageCleanupBatchService.

# B1 (NEGATIVE): MessageRepository.java has no @Transactional annotation.
run B1 "Fix B — MessageRepository.java contains no @Transactional annotation" \
    file_not_contains '@Transactional' "$MSGREPO"

# B2 (NEGATIVE): the Transactional import is also gone.
run B2 "Fix B — MessageRepository.java does not import org.springframework.transaction.annotation.Transactional" \
    file_not_contains 'import\s+org\.springframework\.transaction\.annotation\.Transactional' "$MSGREPO"

# B3: MessageCleanupBatchService.java exists at the expected path.
run B3 "Fix B — MessageCleanupBatchService.java exists at service/job/" \
    bash -c '[ -f "'"$BATCHSVC"'" ]'

# B4: MessageCleanupBatchService is @Service.
run B4 "Fix B — MessageCleanupBatchService is annotated @Service" \
    file_contains '@Service' "$BATCHSVC"

# B5: archiveOnce has @Transactional(tenantTransactionManager, REQUIRES_NEW).
# Guards with test -f first — perl -0777 -ne on a missing file exits 0 (false-pass risk).
run B5 "Fix B — MessageCleanupBatchService.archiveOnce has @Transactional(tenantTransactionManager, REQUIRES_NEW)" \
    bash -c '
        test -f "'"$BATCHSVC"'" || exit 1
        perl -0777 -ne "exit 0 if /\@Transactional\([^)]*tenantTransactionManager[^)]*REQUIRES_NEW[\s\S]{0,300}?archiveOnce/m; exit 1" \
            "'"$BATCHSVC"'" 2>/dev/null \
        || perl -0777 -ne "exit 0 if /\@Transactional\([^)]*REQUIRES_NEW[^)]*tenantTransactionManager[\s\S]{0,300}?archiveOnce/m; exit 1" \
            "'"$BATCHSVC"'" 2>/dev/null
    '

# B6: deleteOnce has the same annotation shape.
run B6 "Fix B — MessageCleanupBatchService.deleteOnce has @Transactional(tenantTransactionManager, REQUIRES_NEW)" \
    bash -c '
        test -f "'"$BATCHSVC"'" || exit 1
        perl -0777 -ne "exit 0 if /\@Transactional\([^)]*tenantTransactionManager[^)]*REQUIRES_NEW[\s\S]{0,300}?deleteOnce/m; exit 1" \
            "'"$BATCHSVC"'" 2>/dev/null \
        || perl -0777 -ne "exit 0 if /\@Transactional\([^)]*REQUIRES_NEW[^)]*tenantTransactionManager[\s\S]{0,300}?deleteOnce/m; exit 1" \
            "'"$BATCHSVC"'" 2>/dev/null
    '

# B7: CleanUpOldMessageJobService injects and references MessageCleanupBatchService.
run B7 "Fix B — CleanUpOldMessageJobService references MessageCleanupBatchService" \
    file_contains 'MessageCleanupBatchService' "$CLEANSVC"

echo

# === Fix C — Configurable batch size via sysprop =============================

# C1: WmsConstants declares the new batch-size sysprop key.
run C1 "Fix C — WmsConstants declares SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_BATCH_SIZE_KEY" \
    file_contains 'SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_BATCH_SIZE_KEY' "$WMSC"

# C2: WmsConstants declares the default value constant (allows Java-fallback without sysprop).
run C2 "Fix C — WmsConstants declares SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_BATCH_SIZE_DEFAULT_VALUE" \
    file_contains 'SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_BATCH_SIZE_DEFAULT_VALUE' "$WMSC"

# C3: deleteMessages signature includes @Param("batchSize").
run C3 "Fix C — deleteMessages signature includes @Param(\"batchSize\")" \
    bash -c '
        perl -0777 -ne "exit 0 if /deleteMessages[\s\S]{0,400}?\@Param\(\s*\"batchSize\"\s*\)/m; exit 1" \
            "'"$MSGREPO"'" 2>/dev/null \
        || perl -0777 -ne "exit 0 if /\@Param\(\s*\"batchSize\"\s*\)[\s\S]{0,200}?deleteMessages/m; exit 1" \
            "'"$MSGREPO"'" 2>/dev/null
    '

# C4 (POSITIVE): query uses LIMIT :batchSize (bind parameter, not literal).
run C4 "Fix C — MessageRepository deleteMessages query uses LIMIT :batchSize" \
    file_contains 'LIMIT\s+\:batchSize' "$MSGREPO"

# C5 (NEGATIVE): the hardcoded string-concat literal LIMIT " + 1000 + " is gone.
run C5 "Fix C — MessageRepository no longer contains 'LIMIT \" + 1000 + \"' literal" \
    file_not_contains 'LIMIT\s*\"\s*\+\s*1000\s*\+' "$MSGREPO"

# C6: CleanUpOldMessageJobService reads the BATCH_SIZE sysprop.
run C6 "Fix C — CleanUpOldMessageJobService references SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_BATCH_SIZE_KEY" \
    file_contains 'SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_BATCH_SIZE_KEY' "$CLEANSVC"

echo

# === Fix D — REQUIRES_NEW per loop iteration (combined with Fix B) ===========

# D1: the do-while loop calls deleteOnce (through the batch service proxy).
run D1 "Fix D — CleanUpOldMessageJobService loop calls deleteOnce()" \
    file_contains 'deleteOnce\s*\(' "$CLEANSVC"

# D2: archiveMessage calls archiveOnce (through the proxy bean, not repo directly).
run D2 "Fix D — CleanUpOldMessageJobService calls archiveOnce()" \
    file_contains 'archiveOnce\s*\(' "$CLEANSVC"

# D3 (NEGATIVE): direct messageRepository.deleteMessages call is gone from the service.
run D3 "Fix D — CleanUpOldMessageJobService no longer calls messageRepository.deleteMessages directly" \
    file_not_contains 'messageRepository\.deleteMessages\s*\(' "$CLEANSVC"

# D4 (NEGATIVE): direct messageRepository.archiveMessages call is gone from the service.
run D4 "Fix D — CleanUpOldMessageJobService no longer calls messageRepository.archiveMessages directly" \
    file_not_contains 'messageRepository\.archiveMessages\s*\(' "$CLEANSVC"

echo

# === Fix E — Code cleanup ====================================================

# E1 (POSITIVE): Integer.parseInt replaces Integer.valueOf.
run E1 "Fix E — CleanUpOldMessageJobService uses Integer.parseInt" \
    file_contains 'Integer\.parseInt' "$CLEANSVC"

# E2 (NEGATIVE): Integer.valueOf is gone.
run E2 "Fix E — CleanUpOldMessageJobService no longer uses Integer.valueOf(" \
    file_not_contains 'Integer\.valueOf\s*\(' "$CLEANSVC"

# E3 (NEGATIVE): dead commented-out deleteMessages line is gone.
run E3 "Fix E — CleanUpOldMessageJobService no longer contains commented-out messageRepository.deleteMessages(refDate)" \
    file_not_contains '^\s*//.*messageRepository\.deleteMessages\(refDate\)' "$CLEANSVC"

# E4: BusinessException.java declares INVALID_SYSPROP_VALUE (or InvalidSyspropValue) constant.
run E4 "Fix E — BusinessException.java declares INVALID_SYSPROP_VALUE constant" \
    bash -c '
        test -f "'"$BIZEX"'" || exit 1
        grep -qE "INVALID_SYSPROP_VALUE|InvalidSyspropValue" "'"$BIZEX"'" 2>/dev/null
    '

# E5: messages_en_US.properties contains the new i18n key.
run E5 "Fix E — messages_en_US.properties contains BusinessException.InvalidSyspropValue" \
    bash -c '
        test -f "'"$MSGS"'" || exit 1
        grep -qE "^BusinessException\.InvalidSyspropValue=" "'"$MSGS"'" 2>/dev/null
    '

echo

# === Fix F — HAL exposure suppression on MessageRepository ===================
# Scope: MessageRepository.java only (see plan §0 out-of-scope note for the
# seven other repos that carry the same pattern but are deferred to a follow-up ticket).

# F1: archiveMessages has @RestResource(exported = false).
run F1 "Fix F — MessageRepository.archiveMessages has @RestResource(exported = false)" \
    bash -c '
        perl -0777 -ne "exit 0 if /\@RestResource\s*\(\s*exported\s*=\s*false\s*\)[\s\S]{0,300}?archiveMessages/m; exit 1" \
            "'"$MSGREPO"'" 2>/dev/null
    '

# F2: deleteMessages has @RestResource(exported = false).
run F2 "Fix F — MessageRepository.deleteMessages has @RestResource(exported = false)" \
    bash -c '
        perl -0777 -ne "exit 0 if /\@RestResource\s*\(\s*exported\s*=\s*false\s*\)[\s\S]{0,300}?deleteMessages/m; exit 1" \
            "'"$MSGREPO"'" 2>/dev/null
    '

# F3: at least 2 @RestResource(exported = false) in the file (one per method).
run F3 "Fix F — MessageRepository.java contains >=2 @RestResource(exported = false) annotations" \
    bash -c '
        count=$(grep -cE "@RestResource\s*\(\s*exported\s*=\s*false\s*\)" "'"$MSGREPO"'" 2>/dev/null)
        [ "${count:-0}" -ge 2 ]
    '

# F4 (NEGATIVE): the old @RestResource(path = "deleteMessages") form is gone.
run F4 "Fix F — @RestResource(path = \"deleteMessages\") no longer present in MessageRepository" \
    file_not_contains '@RestResource\s*\(\s*path\s*=\s*"deleteMessages"' "$MSGREPO"

# F5 (NEGATIVE): the old @RestResource(path = "archiveMessages") form is gone.
run F5 "Fix F — @RestResource(path = \"archiveMessages\") no longer present in MessageRepository" \
    file_not_contains '@RestResource\s*\(\s*path\s*=\s*"archiveMessages"' "$MSGREPO"

echo

# === Fix G — Optional Thread.sleep throttle via Sleeper interface ============

# G1: WmsConstants declares the sleep-ms sysprop key.
run G1 "Fix G — WmsConstants declares SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_BATCH_SLEEP_MS_KEY" \
    file_contains 'SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_BATCH_SLEEP_MS_KEY' "$WMSC"

# G2: WmsConstants declares the default value (expected: "0").
run G2 "Fix G — WmsConstants declares SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_BATCH_SLEEP_MS_DEFAULT_VALUE" \
    file_contains 'SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_BATCH_SLEEP_MS_DEFAULT_VALUE' "$WMSC"

# G3: CleanUpOldMessageJobService references the sleep sysprop key.
run G3 "Fix G — CleanUpOldMessageJobService references SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_BATCH_SLEEP_MS_KEY" \
    file_contains 'SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_BATCH_SLEEP_MS_KEY' "$CLEANSVC"

# G4: CleanUpOldMessageJobService uses Sleeper interface (testable sleep injection).
# Accept a Sleeper reference in the service OR a standalone Sleeper.java in the package.
run G4 "Fix G — CleanUpOldMessageJobService uses Sleeper interface (testable sleep injection)" \
    bash -c '
        grep -qE "Sleeper|sleeper\." "'"$CLEANSVC"'" 2>/dev/null \
        || find src/main/java/net/aim_ai/wms/service/job/ -name "Sleeper.java" 2>/dev/null | grep -q "."
    '

echo

# === Test wiring ==============================================================

# T1: CleanUpOldMessageJobServiceUnitTest references the BATCH_SIZE sysprop.
run T1 "Test — CleanUpOldMessageJobServiceUnitTest references BATCH_SIZE_KEY" \
    bash -c '
        test -f "'"$CLEANSVC_TEST"'" && \
        grep -qE "SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_BATCH_SIZE_KEY|BATCH_SIZE_KEY" \
            "'"$CLEANSVC_TEST"'" 2>/dev/null
    '

# T2: CleanUpOldMessageJobServiceUnitTest references the new batch-service indirection.
run T2 "Test — CleanUpOldMessageJobServiceUnitTest references MessageCleanupBatchService/deleteOnce/archiveOnce" \
    bash -c '
        test -f "'"$CLEANSVC_TEST"'" && \
        grep -qE "MessageCleanupBatchService|deleteOnce|archiveOnce" "'"$CLEANSVC_TEST"'" 2>/dev/null
    '

# T3: MessageCleanupBatchServiceUnitTest exists.
run T3 "Test — MessageCleanupBatchServiceUnitTest.java exists" \
    bash -c '[ -f "'"$BATCHSVC_TEST"'" ]'

# T4: MessageCleanupBatchServiceUnitTest asserts REQUIRES_NEW + tenantTransactionManager annotation.
run T4 "Test — MessageCleanupBatchServiceUnitTest asserts REQUIRES_NEW + tenantTransactionManager" \
    bash -c '
        test -f "'"$BATCHSVC_TEST"'" && \
        grep -qE "REQUIRES_NEW" "'"$BATCHSVC_TEST"'" 2>/dev/null && \
        grep -qE "tenantTransactionManager" "'"$BATCHSVC_TEST"'" 2>/dev/null
    '

# T5: MessageCleanupBatchServiceUnitTest includes a Spring-context IT asserting the proxy
# opens a distinct tx (not just reflection — actual runtime proxy assertion).
run T5 "Test — MessageCleanupBatchServiceUnitTest includes Spring-context proxy/tx assertion" \
    bash -c '
        test -f "'"$BATCHSVC_TEST"'" && \
        grep -qE "TransactionSynchronizationManager|getCurrentTransactionName|SpringBootTest|SpringJUnitConfig" \
            "'"$BATCHSVC_TEST"'" 2>/dev/null
    '

# T6: MessageRepositoryIntegrationTest references the new batchSize parameter.
run T6 "Test — MessageRepositoryIntegrationTest references batchSize parameter (updated signature)" \
    bash -c '
        test -f "'"$MSGREPO_IT"'" && \
        grep -qE "deleteMessages\s*\([^)]*,\s*[0-9]+\s*\)|batchSize" "'"$MSGREPO_IT"'" 2>/dev/null
    '

# T7: MessageRepositoryIntegrationTest deleteMessages nested class is no longer @Disabled
# (committed to Postgres via Testcontainers / @Tag("postgres") per plan §6 H2/Postgres note).
run T7 "Test — MessageRepositoryIntegrationTest deleteMessages class is no longer plain @Disabled (uses @Tag or Testcontainers)" \
    bash -c '
        test -f "'"$MSGREPO_IT"'" || exit 1
        # PASS if @Tag("postgres") appears within 200 chars before "class DeleteMessages"
        # (not just anywhere in the file — other nested classes might also carry @Tag)
        if perl -0777 -ne "exit 0 if /\@Tag\s*\(\s*\"postgres\"\s*\)[\s\S]{0,200}?class DeleteMessages/m; exit 1" \
                "'"$MSGREPO_IT"'" 2>/dev/null; then
            exit 0
        fi
        # PASS if @Disabled is no longer within 200 chars of "deleteMessages" nested class
        ! perl -0777 -ne "exit 0 if /\@Disabled[\s\S]{0,200}?class DeleteMessages/m; exit 1" \
            "'"$MSGREPO_IT"'" 2>/dev/null
    '

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T-CLEAN "Test — mvn test -Dtest=CleanUpOldMessageJobServiceUnitTest passes" \
        mvn_test_passes CleanUpOldMessageJobServiceUnitTest
    run T-BATCH "Test — mvn test -Dtest=MessageCleanupBatchServiceUnitTest passes" \
        mvn_test_passes MessageCleanupBatchServiceUnitTest
    run T-IT "Test — mvn failsafe:integration-test -Dit.test=MessageRepositoryIntegrationTest passes" \
        mvn_it_passes MessageRepositoryIntegrationTest
else
    skip T-CLEAN "Test — CleanUpOldMessageJobServiceUnitTest run" "SKIP_MVN=1 set"
    skip T-BATCH "Test — MessageCleanupBatchServiceUnitTest run" "SKIP_MVN=1 set"
    skip T-IT    "Test — MessageRepositoryIntegrationTest run" "SKIP_MVN=1 set"
fi

echo

# === MessageRepository-scoped hardening ======================================
# These checks are scoped to MessageRepository.java and the application config —
# NOT to the other seven repos that carry pre-existing @Modifying+@RestResource
# patterns (out of scope; see plan §0 and follow-up hygiene ticket).

# H1: MessageRepository.java contains no @Async annotation after Fix A.
run H1 "Hardening — MessageRepository.java contains no @Async annotation (Fix A scope)" \
    file_not_contains '@Async' "$MSGREPO"

# H2: MessageRepository.java contains no @Transactional annotation after Fix B.
run H2 "Hardening — MessageRepository.java contains no @Transactional annotation (Fix B scope)" \
    file_not_contains '@Transactional' "$MSGREPO"

# H3: No @EnableAsync introduced anywhere in src/main/java.
# If @EnableAsync appears, any @Async annotation that creeps back into repos would
# immediately activate the async proxy — the footgun this plan is guarding against.
run H3 "Hardening — no @EnableAsync present anywhere in src/main/java (async infrastructure absent)" \
    bash -c '
        count=$(grep -rE "@EnableAsync|@AsyncConfigurer" src/main/java/ 2>/dev/null | wc -l)
        [ "${count:-0}" -eq 0 ]
    '

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
