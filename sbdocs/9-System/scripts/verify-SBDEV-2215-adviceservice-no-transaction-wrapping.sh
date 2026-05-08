#!/usr/bin/env bash
# verify-SBDEV-2215-adviceservice-no-transaction-wrapping.sh
#
# Acceptance for plan `SBDEV-2215-adviceservice-no-transaction-wrapping.md`.
#
# This is a regression-guard plan: AdviceService's three named methods
# (acceptHubAndSpokeAdvice, close, acceptTransferAdvice) are ALREADY fixed
# in v2 — each has its own @Transactional(value="tenantTransactionManager")
# annotation, and each calls omsNotificationService.sendAfterCommit(...)
# instead of an inline httpRestService.post(...). The fixes shipped under
# v2 commit 41cf1f3 (the SBDEV-2214 sweep). This script LOCKS THEM IN.
#
# It also asserts the new AdviceServiceRollbackIntegrationTest exists with
# the ticket-mandated rollback-assertion test methods.
#
# Runs against v2/wms2-api by default; override with PROJECT_ROOT=/path/to/wms2-api.
# A "DONE" claim is not accepted while this script reports any FAIL.
#
# See sbdocs/9-System/templates/verify-plan-template.sh for the design notes,
# and sbdocs/9-System/scripts/verify-SBDEV-2214-oms-http-post-inside-class-level-transactional.sh
# for the sibling plan that established this script's check style.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/Users/np1076/dev/spk/owl/v2/wms2-api}"
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

# --- assertion helpers (file-scoped, used inside the run callsites below) ---
file_contains() { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { ! grep -qE "$1" "$2" 2>/dev/null; }

# Multi-line regex: uses perl -0777 to match across newlines (BSD grep -z is unreliable on macOS).
# Returns failure if the file does not exist.
file_contains_ml() {
    [ -f "$2" ] || return 1
    PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null
}

file_count_at_least() {
    local pat=$1 file=$2 n=$3
    local c
    c=$(grep -cE "$pat" "$file" 2>/dev/null || echo 0)
    [ "$c" -ge "$n" ]
}

# Assert that EVERY @Transactional( line in the file contains tenantTransactionManager.
# Equivalent to: there is no @Transactional( line missing the qualifier.
all_transactional_have_tenant_tm() {
    local file=$1
    [ -f "$file" ] || return 1
    # Count @Transactional( occurrences that DON'T mention tenantTransactionManager on the same line.
    # Note: @TransactionalEventListener should not be matched — we anchor on @Transactional( specifically.
    local bad
    bad=$(grep -E '@Transactional\(' "$file" \
        | grep -v 'TransactionalEventListener' \
        | grep -vE 'tenantTransactionManager' \
        | wc -l \
        | tr -d ' ')
    [ "$bad" -eq 0 ]
}

mvn_test_passes() {
    local cls=$1
    mvn test -Dtest="$cls" -DfailIfNoTests=false >/dev/null 2>&1
}

mvn_verify_test_passes() {
    local cls=$1
    mvn verify -Dtest="$cls" -DfailIfNoTests=false -DskipUnitTests=false >/dev/null 2>&1
}

SVC=src/main/java/net/aim_ai/wms/service
TST=src/test/java/net/aim_ai/wms

ADV_SVC=$SVC/AdviceService.java
OMS_HELPER=$SVC/OmsNotificationService.java
MSG_SVC=$SVC/MessageService.java
ADV_CTRL=src/main/java/net/aim_ai/wms/controller/AdviceController.java
ADM_CTRL=src/main/java/net/aim_ai/wms/controller/AdminController.java

ADV_UT=$TST/unit/service/AdviceServiceUnitTest.java
ADV_H2=$TST/unit/service/AdviceServiceH2Test.java
ADV_IT=$TST/integration/service/AdviceServiceIntegrationTest.java
OMS_UT=$TST/unit/service/OmsNotificationServiceUnitTest.java
ADV_RB=$TST/integration/service/AdviceServiceRollbackIntegrationTest.java

echo
echo "verify-SBDEV-2215 — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# ============================================================================
# §A — Helper service that this plan depends on (must already exist on v2;
#       SBDEV-2214's §A — replicated here so this script is self-contained)
# ============================================================================

run A1 "OmsNotificationService.java exists" \
    test -f "$OMS_HELPER"
run A2 "OmsNotificationService.sendAfterCommit method present" \
    file_contains 'public void sendAfterCommit\(String urlPath, String payload, String processType\)' "$OMS_HELPER"
run A3 "OmsNotificationService uses TransactionSynchronizationManager.registerSynchronization" \
    file_contains 'TransactionSynchronizationManager\.registerSynchronization' "$OMS_HELPER"
run A4 "OmsNotificationService writes a Message audit row in doSend (SENT or FAILED)" \
    file_contains 'messageService\.createMessage' "$OMS_HELPER"
run A5 "MessageService.createServiceLog still has REQUIRES_NEW (audit-row survives outer rollback)" \
    file_contains_ml '@Transactional\(value\s*=\s*"tenantTransactionManager",\s*propagation\s*=\s*Propagation\.REQUIRES_NEW\)\s*\n\s*public Message createServiceLog' "$MSG_SVC"

echo

# ============================================================================
# §B — AdviceService file-level firewalls (NEGATIVE checks — top-level)
# ============================================================================

run B1 "B1 — AdviceService.java exists" \
    test -f "$ADV_SVC"
run B2 "B2 — AdviceService.java contains NO inline httpRestService.post (top-level firewall)" \
    file_not_contains 'httpRestService\.post\(' "$ADV_SVC"
run B3 "B3 — Every @Transactional in AdviceService.java specifies tenantTransactionManager (R5 firewall)" \
    all_transactional_have_tenant_tm "$ADV_SVC"
run B4 "B4 — No self-invocation of acceptHubAndSpokeAdvice (proxy-bypass firewall, R4)" \
    file_not_contains 'this\.acceptHubAndSpokeAdvice\(' "$ADV_SVC"
run B5 "B5 — No self-invocation of close(...) on the service self-reference (proxy-bypass firewall, R4)" \
    file_not_contains 'this\.close\(' "$ADV_SVC"
run B6 "B6 — No self-invocation of acceptTransferAdvice (proxy-bypass firewall, R4)" \
    file_not_contains 'this\.acceptTransferAdvice\(' "$ADV_SVC"
run B7 "B7 — Bulk JPQL UPDATE (updateAdvicepositionToStateByAdviceId) appears at least 2× (R7 — close + acceptTransferAdvice)" \
    file_count_at_least 'advicepositionRepository\.updateAdvicepositionToStateByAdviceId\(' "$ADV_SVC" 2

echo

# ============================================================================
# §C — Bug 1 (already fixed): acceptHubAndSpokeAdvice — regression guards
# ============================================================================

# C1 — annotation immediately preceding the method signature
run C1a "C1.a — acceptHubAndSpokeAdvice has @Transactional(tenantTransactionManager, rollbackFor BusinessException+FacadeException)" \
    file_contains_ml '@Transactional\(value\s*=\s*"tenantTransactionManager",\s*rollbackFor\s*=\s*\{BusinessException\.class,\s*FacadeException\.class\}\)\s*\n\s*public void acceptHubAndSpokeAdvice' "$ADV_SVC"
run C1b "C1.b — acceptHubAndSpokeAdvice body calls omsNotificationService.sendAfterCommit(... ADVICE_HUB_AND_SPOKE_RECEIVED)" \
    file_contains_ml 'omsNotificationService\.sendAfterCommit\([^)]*ADVICE_HUB_AND_SPOKE_RECEIVED' "$ADV_SVC"
run C1c "C1.c — acceptHubAndSpokeAdvice body declares advice.setState(FINISHED) (state mutation present — guards against accidental no-op refactor)" \
    file_contains 'advice\.setState\(WmsConstants\.AdviceState\.FINISHED\)' "$ADV_SVC"

echo

# ============================================================================
# §D — Bug 2 (already fixed): close — regression guards
# ============================================================================

run D1a "D1.a — close has @Transactional(tenantTransactionManager, rollbackFor BusinessException+FacadeException)" \
    file_contains_ml '@Transactional\(value\s*=\s*"tenantTransactionManager",\s*rollbackFor\s*=\s*\{BusinessException\.class,\s*FacadeException\.class\}\)\s*\n\s*public void close\(Advice advice, Principal principal\)' "$ADV_SVC"
run D1b "D1.b — close body calls omsNotificationService.sendAfterCommit(... ADVICE_CLOSE)" \
    file_contains_ml 'omsNotificationService\.sendAfterCommit\([^)]*ADVICE_CLOSE\b' "$ADV_SVC"
run D1c "D1.c — close body uses adviceRepository.saveAndFlush (so the bulk JPQL UPDATE sees flushed state)" \
    file_contains 'adviceRepository\.saveAndFlush\(advice\)' "$ADV_SVC"

echo

# ============================================================================
# §E — Bug 3 (already fixed): acceptTransferAdvice — regression guards
# ============================================================================

run E1a "E1.a — acceptTransferAdvice has @Transactional(tenantTransactionManager, rollbackFor BusinessException+FacadeException)" \
    file_contains_ml '@Transactional\(value\s*=\s*"tenantTransactionManager",\s*rollbackFor\s*=\s*\{BusinessException\.class,\s*FacadeException\.class\}\)\s*\n\s*public void acceptTransferAdvice' "$ADV_SVC"
run E1b "E1.b — acceptTransferAdvice body calls omsNotificationService.sendAfterCommit(... ADVICE_ACCEPT_TRANSFER)" \
    file_contains_ml 'omsNotificationService\.sendAfterCommit\([^)]*ADVICE_ACCEPT_TRANSFER' "$ADV_SVC"

echo

# ============================================================================
# §F — Adjacent regression-guard: fixHubAndSpokePalletIssues
# ============================================================================

run F1 "F1 — fixHubAndSpokePalletIssues has @Transactional(tenantTransactionManager, rollbackFor BusinessException+FacadeException)" \
    file_contains_ml '@Transactional\(value\s*=\s*"tenantTransactionManager",\s*rollbackFor\s*=\s*\{BusinessException\.class,\s*FacadeException\.class\}\)\s*\n\s*public void fixHubAndSpokePalletIssues' "$ADV_SVC"

echo

# ============================================================================
# §G — Caller layer must not be @Transactional (R6 — controller-side firewall)
# ============================================================================

run G1 "G1 — AdviceController is not @Transactional" \
    file_not_contains '@Transactional' "$ADV_CTRL"
run G2 "G2 — AdminController is not @Transactional (R6 — base class shouldn't impose a tx on AdviceController)" \
    bash -c "test ! -f '$ADM_CTRL' || ! grep -qE '@Transactional' '$ADM_CTRL'"

echo

# ============================================================================
# §H — NEW integration test class: AdviceServiceRollbackIntegrationTest
# ============================================================================

run H1   "H1 — AdviceServiceRollbackIntegrationTest.java exists (NEW)" \
    test -f "$ADV_RB"
run H2   "H2 — declares acceptHubAndSpokeAdvice_shouldRollbackAllPositions_andNotPostToOms_whenMidLoopExceptionThrown (TICKET-MANDATED)" \
    bash -c "test -f '$ADV_RB' && grep -qE 'acceptHubAndSpokeAdvice_shouldRollbackAllPositions_andNotPostToOms_whenMidLoopExceptionThrown' '$ADV_RB'"
run H3   "H3 — declares close_shouldRollbackAdviceAndPositions_andNotPostToOms_whenLaterStepThrows" \
    bash -c "test -f '$ADV_RB' && grep -qE 'close_shouldRollbackAdviceAndPositions_andNotPostToOms_whenLaterStepThrows' '$ADV_RB'"
run H4   "H4 — declares acceptTransferAdvice_shouldRollbackAdviceAndPositions_andNotPostToOms_whenLaterStepThrows" \
    bash -c "test -f '$ADV_RB' && grep -qE 'acceptTransferAdvice_shouldRollbackAdviceAndPositions_andNotPostToOms_whenLaterStepThrows' '$ADV_RB'"
run H5   "H5 — extends BaseIntegrationTest (Testcontainers PostgreSQL)" \
    bash -c "test -f '$ADV_RB' && grep -qE 'extends BaseIntegrationTest' '$ADV_RB'"
run H6   "H6 — uses Mockito to verify httpRestService.post is never called (rollback assertion)" \
    bash -c "test -f '$ADV_RB' && grep -qE 'verify\(httpRestService.*never\(\)\)\.post' '$ADV_RB'"

echo

# ============================================================================
# §I — Existing test classes must remain green (regression suite)
# ============================================================================

run I1 "I1 — AdviceServiceUnitTest.java exists" \
    test -f "$ADV_UT"
run I2 "I2 — AdviceServiceH2Test.java exists" \
    test -f "$ADV_H2"
run I3 "I3 — AdviceServiceIntegrationTest.java exists" \
    test -f "$ADV_IT"
run I4 "I4 — OmsNotificationServiceUnitTest.java exists" \
    test -f "$OMS_UT"

echo

# ============================================================================
# §J — Targeted maven test runs (skipped if SKIP_MVN=1 in env)
# ============================================================================

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run J1 "J1 — AdviceServiceUnitTest passes"               mvn_test_passes AdviceServiceUnitTest
    run J2 "J2 — AdviceServiceH2Test passes"                 mvn_test_passes AdviceServiceH2Test
    run J3 "J3 — OmsNotificationServiceUnitTest passes"      mvn_test_passes OmsNotificationServiceUnitTest
    run J4 "J4 — AdviceServiceIntegrationTest passes"        mvn_verify_test_passes AdviceServiceIntegrationTest
    run J5 "J5 — AdviceServiceRollbackIntegrationTest passes (NEW)" mvn_verify_test_passes AdviceServiceRollbackIntegrationTest
else
    skip J-mvn "Targeted unit/integration test runs"  "SKIP_MVN=1 set"
fi

echo

# ============================================================================
# §K — Adjacent regression-guards (sibling-plan invariants must remain CLEAN)
# ============================================================================

run K1 "K1 — BillofladingService still uses sendAfterCommit (sibling site)" \
    file_contains 'omsNotificationService\.sendAfterCommit\(' "$SVC/BillofladingService.java"
run K2 "K2 — CustomerorderService still uses sendAfterCommit (SBDEV-2214 sibling site)" \
    file_contains 'omsNotificationService\.sendAfterCommit\(' "$SVC/CustomerorderService.java"
run K3 "K3 — CustomerorderBatchService still uses sendAfterCommit (SBDEV-2214 sibling site)" \
    file_contains 'omsNotificationService\.sendAfterCommit\(' "$SVC/CustomerorderBatchService.java"

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
