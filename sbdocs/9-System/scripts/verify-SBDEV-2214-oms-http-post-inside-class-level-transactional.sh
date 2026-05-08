#!/usr/bin/env bash
# verify-SBDEV-2214-oms-http-post-inside-class-level-transactional.sh
#
# Acceptance for plan `SBDEV-2214-oms-http-post-inside-class-level-transactional.md`.
#
# This plan verifies + extends the post-commit OMS-notification pattern in v2/wms2-api:
#   - Bug 1 / Bug 2 (already fixed): regression guards for CustomerorderService.cancelOrder
#     and CustomerorderBatchService.cancelBatch — annotation-adjacency + method-scoped
#     positive checks (per critic-M1 single-line annotation regex; v2 uses METHOD-LEVEL
#     @Transactional, not class-level, so the checks bind annotation-to-method-decl).
#   - Bug 3 (Fix A): refactor ManageOrderService × 7 method bodies to delegate to
#     omsNotificationService.sendAfterCommit — checks are method_body_contains-scoped,
#     so a file-level grep cannot produce a false PASS.
#   - Bug 4 (Fix B): refactor MessageService.sendStockChangeMessage via a new
#     StockChangeNotificationService.sendAfterCommit (Shape 1 only — no Shape 2 fallback).
#   - Fix C (mandatory, per critic-M5): Micrometer counter
#     wms2.oms.notification.failed{tenant, processType} wired in OmsNotificationService.doSend's
#     failure branch so the post-fix silent-loss surface is observable.
#
# Runs against v2/wms2-api by default; override with PROJECT_ROOT=/path/to/wms2-api.
# A "DONE" claim is not accepted while this script reports any FAIL.
#
# See sbdocs/9-System/templates/verify-plan-template.sh for the design notes.

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
# Returns failure if the file does not exist (perl -0777 with no input prints nothing and exits 0
# from the END block — guard explicitly so missing files fail the check).
file_contains_ml() {
    [ -f "$2" ] || return 1
    PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null
}

# Match a regex inside a method body. Walks from the method signature, tracks brace depth, and
# tests the slice (signature line up to the matching closing brace) against the second regex.
# Implemented in perl because BSD awk on macOS rejects unescaped parens / anchors in user
# regexes (e.g. `omsNotificationService\.sendAfterCommit\(` triggers `illegal primary in regular
# expression`), which silently turned 11 method-scoped checks into permanent FAILs.
# usage: method_body_contains <method-signature-regex> <forbidden-regex> <file>
method_body_contains() {
    local sig=$1 forbidden=$2 file=$3
    [ -f "$file" ] || return 1
    SIG="$sig" FB="$forbidden" perl -0777 -ne '
        my $sig = $ENV{SIG}; my $fb = $ENV{FB};
        while (/$sig/g) {
            my $start = $-[0];
            my $depth = 0; my $pos = $start; my $len = length($_);
            my $seen_open = 0;
            while ($pos < $len) {
                my $c = substr($_, $pos, 1);
                if ($c eq "{") { $depth++; $seen_open = 1; }
                if ($c eq "}") { $depth--; last if $seen_open && $depth == 0; }
                $pos++;
            }
            my $body = substr($_, $start, $pos - $start + 1);
            exit 0 if $body =~ /$fb/;
        }
        exit 1
    ' "$file"
}

# usage: method_body_not_contains <method-signature-regex> <forbidden-regex> <file>
method_body_not_contains() {
    local sig=$1 forbidden=$2 file=$3
    [ -f "$file" ] || return 1
    SIG="$sig" FB="$forbidden" perl -0777 -ne '
        my $sig = $ENV{SIG}; my $fb = $ENV{FB};
        my $found_any = 0;
        while (/$sig/g) {
            $found_any = 1;
            my $start = $-[0];
            my $depth = 0; my $pos = $start; my $len = length($_);
            my $seen_open = 0;
            while ($pos < $len) {
                my $c = substr($_, $pos, 1);
                if ($c eq "{") { $depth++; $seen_open = 1; }
                if ($c eq "}") { $depth--; last if $seen_open && $depth == 0; }
                $pos++;
            }
            my $body = substr($_, $start, $pos - $start + 1);
            exit 1 if $body =~ /$fb/;
        }
        # If the signature was never found we cannot meaningfully assert "method body
        # does not contain X" — treat as failure so a renamed/deleted method does not
        # silently PASS.
        exit ($found_any ? 0 : 1);
    ' "$file"
}

file_count_at_least() {
    local pat=$1 file=$2 n=$3
    local c
    c=$(grep -cE "$pat" "$file" 2>/dev/null || echo 0)
    [ "$c" -ge "$n" ]
}

mvn_test_passes() {
    local cls=$1
    mvn test -Dtest="$cls" -DfailIfNoTests=false >/dev/null 2>&1
}

SVC=src/main/java/net/aim_ai/wms/service
TST=src/test/java/net/aim_ai/wms

echo
echo "verify-SBDEV-2214 — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# ============================================================================
# §A — Helper service that this plan depends on (must already exist on v2)
# ============================================================================

OMS_HELPER=$SVC/OmsNotificationService.java

run A1 "OmsNotificationService.java exists" \
    test -f "$OMS_HELPER"
run A2 "OmsNotificationService.sendAfterCommit method present" \
    file_contains 'public void sendAfterCommit\(String urlPath, String payload, String processType\)' "$OMS_HELPER"
run A3 "OmsNotificationService uses TransactionSynchronizationManager.registerSynchronization" \
    file_contains 'TransactionSynchronizationManager\.registerSynchronization' "$OMS_HELPER"
run A4 "OmsNotificationService writes a Message audit row in doSend (SENT or FAILED)" \
    file_contains 'messageService\.createMessage' "$OMS_HELPER"

echo

# ============================================================================
# §B — Bug 1: CustomerorderService.cancelOrder — regression guard (already fixed)
# ============================================================================

CO_SVC=$SVC/CustomerorderService.java

run B1a "B1 — cancelOrder still uses omsNotificationService.sendAfterCommit(... ORDER_BATCH_CANCELLED_FROM_WMS ...) (multi-line argument support)" \
    file_contains_ml 'omsNotificationService\.sendAfterCommit\([^;]*ORDER_BATCH_CANCELLED_FROM_WMS' "$CO_SVC"
run B1a2 "B1.a2 — cancelOrder method body invokes omsNotificationService.sendAfterCommit (method-scoped)" \
    method_body_contains 'public void cancelOrder' 'omsNotificationService\.sendAfterCommit\(' "$CO_SVC"
run B1b "B1 — CustomerorderService.java contains NO inline httpRestService.post (regression guard)" \
    file_not_contains 'httpRestService\.post\(' "$CO_SVC"
run B1c "B1 — cancelOrder method is method-level @Transactional with tenantTransactionManager (annotation-adjacent regex)" \
    file_contains_ml '@Transactional\([^\n]*tenantTransactionManager[^\n]*\)\s*\n\s*public void cancelOrder' "$CO_SVC"

echo

# ============================================================================
# §C — Bug 2: CustomerorderBatchService.cancelBatch — regression guard (already fixed)
# ============================================================================

CB_SVC=$SVC/CustomerorderBatchService.java

run C1a "C1 — cancelBatch still uses omsNotificationService.sendAfterCommit(... ORDER_BATCH_CANCELLED_FROM_WMS ...) (multi-line argument support)" \
    file_contains_ml 'omsNotificationService\.sendAfterCommit\([^;]*ORDER_BATCH_CANCELLED_FROM_WMS' "$CB_SVC"
run C1a2 "C1.a2 — cancelBatch method body invokes omsNotificationService.sendAfterCommit (method-scoped)" \
    method_body_contains 'public void cancelBatch' 'omsNotificationService\.sendAfterCommit\(' "$CB_SVC"
run C1b "C1 — CustomerorderBatchService.java contains NO inline httpRestService.post (regression guard)" \
    file_not_contains 'httpRestService\.post\(' "$CB_SVC"
run C1c "C1 — cancelBatch method is method-level @Transactional with tenantTransactionManager (annotation-adjacent regex)" \
    file_contains_ml '@Transactional\([^\n]*tenantTransactionManager[^\n]*\)\s*\n\s*public void cancelBatch' "$CB_SVC"

echo

# ============================================================================
# §D — Bug 3 (Fix A): ManageOrderService × 7 methods refactored
# ============================================================================

MO_SVC=$SVC/ManageOrderService.java

run D1   "D1 — ManageOrderService injects OmsNotificationService (constructor parameter)" \
    file_contains 'OmsNotificationService\s+omsNotificationService' "$MO_SVC"
run D2   "D2 — ManageOrderService invokes omsNotificationService.sendAfterCommit at least 7×" \
    file_count_at_least 'omsNotificationService\.sendAfterCommit\(' "$MO_SVC" 7
run D2a  "D2a — customerOrderOnHold method body contains omsNotificationService.sendAfterCommit (per-method)" \
    method_body_contains 'public void customerOrderOnHold' 'omsNotificationService\.sendAfterCommit\(' "$MO_SVC"
run D2b  "D2b — customerOrderPicked method body contains omsNotificationService.sendAfterCommit (per-method)" \
    method_body_contains 'public void customerOrderPicked' 'omsNotificationService\.sendAfterCommit\(' "$MO_SVC"
run D3   "D3 — ManageOrderService contains NO inline httpRestService.post (all 7 sites converted)" \
    file_not_contains 'httpRestService\.post\(' "$MO_SVC"
run D3a  "D3a — ManageOrderService no longer constructor-injects HttpRestService (Phase 3 cleanup)" \
    file_not_contains 'private final HttpRestService\s+httpRestService' "$MO_SVC"
run D3b  "D3b — ManageOrderService no longer constructor-injects MessageService (Phase 3 cleanup)" \
    file_not_contains 'private final MessageService\s+messageService' "$MO_SVC"

# Per-method positive checks — bind ORDER_BATCH_* constant to the specific method body via method_body_contains.
# This catches over-claims where the file as a whole contains the constant but a particular method still has the inline POST.
run D4-1 "D4.1 — customerOrderOnHold body wires sendAfterCommit with ORDER_BATCH_ON_HOLD" \
    method_body_contains 'public void customerOrderOnHold' 'sendAfterCommit\(.*ORDER_BATCH_ON_HOLD' "$MO_SVC"
run D4-2 "D4.2 — customerOrderReleaseForPicking body wires sendAfterCommit with ORDER_BATCH_PICKING_RELEASED" \
    method_body_contains 'public void customerOrderReleaseForPicking' 'sendAfterCommit\(.*ORDER_BATCH_PICKING_RELEASED' "$MO_SVC"
run D4-3 "D4.3 — customerOrderToteAssigned body wires sendAfterCommit with ORDER_BATCH_PICKING_TOTE_ASSIGNED" \
    method_body_contains 'public void customerOrderToteAssigned' 'sendAfterCommit\(.*ORDER_BATCH_PICKING_TOTE_ASSIGNED' "$MO_SVC"
run D4-4 "D4.4 — customerOrderPickingStarted body wires sendAfterCommit with ORDER_BATCH_PICKING_STARTED" \
    method_body_contains 'public void customerOrderPickingStarted' 'sendAfterCommit\(.*ORDER_BATCH_PICKING_STARTED' "$MO_SVC"
run D4-5 "D4.5 — customerOrderPicked body wires sendAfterCommit with ORDER_BATCH_PICKING_FINISHED" \
    method_body_contains 'public void customerOrderPicked' 'sendAfterCommit\(.*ORDER_BATCH_PICKING_FINISHED' "$MO_SVC"
run D4-6 "D4.6 — customerOrderPalletized body wires sendAfterCommit with ORDER_BATCH_PALLETIZED" \
    method_body_contains 'public void customerOrderPalletized' 'sendAfterCommit\(.*ORDER_BATCH_PALLETIZED' "$MO_SVC"
run D4-7 "D4.7 — customerOrderLoadedToTruck body wires sendAfterCommit with ORDER_BATCH_LOADED_TO_TRUCK" \
    method_body_contains 'public void customerOrderLoadedToTruck' 'sendAfterCommit\(.*ORDER_BATCH_LOADED_TO_TRUCK' "$MO_SVC"

echo

# ============================================================================
# §E — Bug 4 (Fix B): MessageService.sendStockChangeMessage delegated to new
#       StockChangeNotificationService
# ============================================================================

MS_SVC=$SVC/MessageService.java
SC_SVC=$SVC/StockChangeNotificationService.java

run E1   "E1 — StockChangeNotificationService.java exists (NEW file)" \
    test -f "$SC_SVC"
run E2   "E2 — StockChangeNotificationService.sendAfterCommit method present" \
    file_contains 'public void sendAfterCommit\(' "$SC_SVC"
run E3   "E3 — StockChangeNotificationService delegates to omsNotificationService.sendAfterCommit" \
    file_contains 'omsNotificationService\.sendAfterCommit\(' "$SC_SVC"
run E4   "E4 — StockChangeNotificationService uses STOCK_UPDATE process type" \
    bash -c "test -f '$SC_SVC' && grep -qE 'STOCK_UPDATE' '$SC_SVC'"
run E5   "E5 — sendStockChangeMessage method body in MessageService no longer contains httpRestService.post" \
    method_body_not_contains 'public void sendStockChangeMessage' 'httpRestService\.post' "$MS_SVC"
run E6   "E6 — MessageService.sendStockChangeMessage delegates (calls stockChangeNotificationService.sendAfterCommit OR is removed entirely)" \
    bash -c "grep -qE 'stockChangeNotificationService\.sendAfterCommit' '$MS_SVC' || ! grep -qE 'public void sendStockChangeMessage\(' '$MS_SVC'"
run E7   "E7 — MessageService.createServiceLog still has REQUIRES_NEW (audit-row survives outer rollback)" \
    file_contains_ml '@Transactional\(value = "tenantTransactionManager", propagation = Propagation\.REQUIRES_NEW\)\s*\n\s*public Message createServiceLog' "$MS_SVC"

echo

# ============================================================================
# §F — Tests exist for each fix
# ============================================================================

CO_TEST=$TST/unit/service/CustomerorderServiceUnitTest.java
CB_TEST=$TST/unit/service/CustomerorderBatchServiceUnitTest.java
MO_TEST=$TST/unit/service/ManageOrderServiceUnitTest.java
OMS_TEST=$TST/unit/service/OmsNotificationServiceUnitTest.java
SC_TEST=$TST/unit/service/StockChangeNotificationServiceUnitTest.java
ITG_TEST=$TST/integration/CancelOrderRollbackIntegrationTest.java
SMOKE_TEST=$TST/smoke/OmsNotificationConfigContextLoadTest.java

# Renamed (per critic-M6): the rollback-semantics test moved to integration; the unit test asserts deferral registration only.
run F1a  "F1.a — CustomerorderServiceUnitTest declares cancelOrder_shouldRegisterAfterCommitSynchronization_whenCancellationFromWithinWMS (renamed)" \
    file_contains 'cancelOrder_shouldRegisterAfterCommitSynchronization_whenCancellationFromWithinWMS' "$CO_TEST"
run F1b  "F1.b — CustomerorderServiceUnitTest declares cancelOrder_shouldUseSendAfterCommit_whenCancellationFromWithinWMS" \
    file_contains 'cancelOrder_shouldUseSendAfterCommit_whenCancellationFromWithinWMS' "$CO_TEST"
# CustomerorderServiceUnitTest baseline 87 + 2 new ManageOrder-style tests = 89 floor;
# protects against accidental file rewrite per critic finding (was a meaningless ≥2 gate).
run F1c  "F1.c — CustomerorderServiceUnitTest baseline preserved (87 existing + 2 new ≥ 89 @Test)" \
    file_count_at_least '@Test' "$CO_TEST" 89
run F2   "F2 — CustomerorderBatchServiceUnitTest declares cancelBatch_shouldNotPostToOms_whenLaterMutationThrows" \
    file_contains 'cancelBatch_shouldNotPostToOms_whenLaterMutationThrows' "$CB_TEST"
# CustomerorderBatchServiceUnitTest baseline 89 + 1 new test = 90 floor.
run F2b  "F2b — CustomerorderBatchServiceUnitTest baseline preserved (89 existing + 1 new ≥ 90 @Test)" \
    file_count_at_least '@Test' "$CB_TEST" 90
run F3   "F3 — ManageOrderServiceUnitTest exists (existing 1,502-line file; modify-append, not NEW)" \
    test -f "$MO_TEST"
run F3a  "F3.a — ManageOrderServiceUnitTest covers all 7 customer-order-* methods (≥7 deferral assertions)" \
    file_count_at_least 'shouldDeferOmsPostUntilAfterCommit' "$MO_TEST" 7
run F3b  "F3.b — ManageOrderServiceUnitTest baseline preserved (55 existing + 7 new ≥ 62 @Test)" \
    file_count_at_least '@Test' "$MO_TEST" 62
run F3c  "F3.c — ManageOrderServiceUnitTest declares serialization-exception test (per §8.1)" \
    file_contains 'shouldHandleSerializationException_gracefully' "$MO_TEST"
run F3d  "F3.d — ManageOrderServiceUnitTest declares scheduled-job tenant-context test (M4)" \
    file_contains 'customerOrderOnHold_shouldPropagateTenantContext_whenCalledFromScheduledJob' "$MO_TEST"
# Removed: F3e was redundant with F3a/F5b per third-pass critic — `customerOrderPicked` is
# already a substring of the F3a `customerOrderPicked_shouldDeferOmsPostUntilAfterCommit`
# assertion, so the original F3e check was trivially satisfied.
run F4   "F4 — StockChangeNotificationServiceUnitTest exists with deferral test" \
    bash -c "test -f '$SC_TEST' && grep -qE 'shouldDelegateToOmsNotificationService_whenListNonEmpty' '$SC_TEST'"
run F5   "F5 — CancelOrderRollbackIntegrationTest declares cancelOrder_shouldNotPostToOms_whenPostCancelCleanupThrows" \
    bash -c "test -f '$ITG_TEST' && grep -qE 'cancelOrder_shouldNotPostToOms_whenPostCancelCleanupThrows' '$ITG_TEST'"
run F5b  "F5b — CancelOrderRollbackIntegrationTest declares customerOrderPicked_shouldNotPostToOms_whenCallerTxRollsBack (M7)" \
    bash -c "test -f '$ITG_TEST' && grep -qE 'customerOrderPicked_shouldNotPostToOms_whenCallerTxRollsBack' '$ITG_TEST'"
run F6   "F6 — OmsNotificationServiceUnitTest declares Fix C counter test doSend_shouldIncrementFailureCounter_whenPostThrows (M5)" \
    bash -c "test -f '$OMS_TEST' && grep -qE 'doSend_shouldIncrementFailureCounter_whenPostThrows' '$OMS_TEST'"
run F7   "F7 — OmsNotificationConfigContextLoadTest smoke exists (Spring bean-graph load — Fix B circular-dep guard)" \
    bash -c "test -f '$SMOKE_TEST' && grep -qE '@SpringBootTest' '$SMOKE_TEST'"
run F8   "F8 — CancelOrderRollbackIntegrationTest declares customerOrderOnHold_shouldPreserveTenantContext_acrossSchedulerBoundary (R9 mitigation)" \
    bash -c "test -f '$ITG_TEST' && grep -qE 'customerOrderOnHold_shouldPreserveTenantContext_acrossSchedulerBoundary' '$ITG_TEST'"
run F9   "F9 — OmsNotificationServiceUnitTest declares null-tenant-tag test (NEW-C3 mitigation)" \
    bash -c "test -f '$OMS_TEST' && grep -qE 'shouldUseUnknownTenantTag_whenTenantContextIsNull' '$OMS_TEST'"

echo

# ============================================================================
# §I — Fix C: Micrometer counter wired in OmsNotificationService failure branch
# ============================================================================

run I1   "I1 — OmsNotificationService imports MeterRegistry / has it as a constructor parameter" \
    file_contains 'MeterRegistry\s+meterRegistry' "$OMS_HELPER"
run I2   "I2 — OmsNotificationService increments wms2.oms.notification.failed counter in the failure branch" \
    file_contains 'meterRegistry\.counter\("wms2\.oms\.notification\.failed' "$OMS_HELPER"
run I3   "I3 — Counter is tagged with tenant + processType (operator alerting requirement; multi-line-tolerant)" \
    file_contains_ml 'meterRegistry\.counter\("wms2\.oms\.notification\.failed"[^)]*?"tenant"[^)]*?"processType"' "$OMS_HELPER"

echo

# ============================================================================
# §G — Targeted maven test runs (skipped if SKIP_MVN=1 in env)
# ============================================================================

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run G1 "G1 — CustomerorderServiceUnitTest passes"            mvn_test_passes CustomerorderServiceUnitTest
    run G2 "G2 — CustomerorderBatchServiceUnitTest passes"       mvn_test_passes CustomerorderBatchServiceUnitTest
    run G3 "G3 — ManageOrderServiceUnitTest passes"              mvn_test_passes ManageOrderServiceUnitTest
    run G4 "G4 — StockChangeNotificationServiceUnitTest passes"  mvn_test_passes StockChangeNotificationServiceUnitTest
    run G5 "G5 — CancelOrderRollbackIntegrationTest passes"      mvn_test_passes CancelOrderRollbackIntegrationTest
    run G6 "G6 — OmsNotificationServiceUnitTest passes (Fix C counter test)" mvn_test_passes OmsNotificationServiceUnitTest
    run G7 "G7 — OmsNotificationConfigContextLoadTest passes (Fix B context-load smoke)" mvn_test_passes OmsNotificationConfigContextLoadTest
else
    skip G-mvn "Targeted unit-test runs"  "SKIP_MVN=1 set"
fi

echo

# ============================================================================
# §H — Adjacent-bug guards (these should remain CLEAN — no new in-tx posts elsewhere)
# ============================================================================

run H1 "H1 — BillofladingService still uses sendAfterCommit (reference site)" \
    file_contains 'omsNotificationService\.sendAfterCommit\(' "$SVC/BillofladingService.java"
run H2 "H2 — AdviceService still uses sendAfterCommit at least 3× (acceptHubAndSpoke, closeAdvice, acceptTransfer)" \
    file_count_at_least 'omsNotificationService\.sendAfterCommit\(' "$SVC/AdviceService.java" 3

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
