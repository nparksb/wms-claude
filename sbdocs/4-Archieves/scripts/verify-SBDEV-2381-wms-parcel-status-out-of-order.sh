#!/usr/bin/env bash
# verify-SBDEV-2381-wms-parcel-status-out-of-order.sh
# Machine-checkable acceptance for SBDEV-2381 — WMS V2 sends parcel status updates
# out of order to OMS V2 (outbox dispatch ordering + dual-transport unify).
#
#   $ PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
#       bash sbdocs/9-System/scripts/verify-SBDEV-2381-wms-parcel-status-out-of-order.sh
#
# Exit 0 only if all checks pass. Code-shape greps prove the call exists; the
# `mvn_test_passes` rows prove behavior. Paste this script's `Result:` line in the
# end-of-task report before the work is accepted.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}
skip() { printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

file_contains()      { grep -qE "$1" "$2"; }
file_not_contains()  { ! grep -qE "$1" "$2"; }
file_exists()        { [ -f "$1" ]; }
glob_exists()        { compgen -G "$1" >/dev/null; }
# NOTE: do NOT pass -q here. Under -q, maven suppresses both the "BUILD SUCCESS" line and the
# "Tests run: N, Failures: 0, Errors: 0" surefire/failsafe summary, so the grep can never match
# even when the targeted test passes. surefire (mvn test) honours -Dtest and scopes the aggregate
# summary to the named class, so asserting the green aggregate line is sufficient.
mvn_test_passes() {
    local out
    out="$(mvn test -Dtest="$1" -DfailIfNoTests=false 2>&1)"
    echo "$out" | grep -qE "Tests run: [0-9]+, Failures: 0, Errors: 0" \
        && ! echo "$out" | grep -qE "Tests run: [0-9]+, Failures: [1-9]|Tests run: [0-9]+,.*Errors: [1-9]"
}
# For verify, the project's failsafe config runs the full IT suite regardless of -Dtest, and the
# whole suite carries pre-existing context-load failures unrelated to SBDEV-2381. So assert ONLY on
# the targeted IT class's own per-class summary line being green ("... -- in net...outbox.<IT>"),
# not on the aggregate BUILD result.
mvn_verify_passes() {
    mvn verify -Dtest="$1" -DfailIfNoTests=false 2>&1 \
        | grep -E "Failures: 0, Errors: 0.* -- in net\.aim_ai\.wms\.integration\.outbox\.${1}\b" \
        | grep -q .
}

REPO=src/main/java/net/aim_ai/wms/repo/jpa/OutboxMessageRepository.java
DISP=src/main/java/net/aim_ai/wms/service/job/OutboxDispatchService.java
PICK=src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java
CBATCH=src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java
MANAGE=src/main/java/net/aim_ai/wms/service/ManageOrderService.java
MIG_GLOB='src/main/resources/db/migration/V2.1.14__add_outbox_aggregate_order_index.sql'

# ── Fix A — index-only migration (CONCURRENTLY, non-tx, DROP-IF-EXISTS guard) ──
check_A_migration_exists()        { glob_exists "$MIG_GLOB"; }
check_A_concurrently()            { file_contains 'CREATE INDEX CONCURRENTLY( IF NOT EXISTS)? +index_outbox_message_aggregate_order' "$MIG_GLOB"; }
check_A_non_transactional()       { file_contains 'flyway:executeInTransaction=false' "$MIG_GLOB"; }
check_A_drop_guard()              { file_contains 'DROP INDEX IF EXISTS +index_outbox_message_aggregate_order' "$MIG_GLOB"; }
check_A_no_column()               { file_not_contains 'ADD COLUMN +aggregate_sequence' "$MIG_GLOB"; }   # NEGATIVE: synthetic seq dropped

# ── Fix B — entity NOT changed (no synthetic sequence field) ──
check_B_no_seq_field()            { file_not_contains 'aggregateSequence' src/main/java/net/aim_ai/wms/model/OutboxMessage.java; }

# ── Fix C — deterministic claim order + in-batch Java sort, no MAX+1 ──
check_C_claim_order_by_id()       { file_contains 'ORDER BY +(o\.)?next_attempt_at, *(o\.)?id' "$REPO"; }
check_C_inbatch_sort()            { file_contains '\.sort\(' "$DISP" && file_contains 'thenComparing\(OutboxMessage::getId\)' "$DISP"; }
check_C_no_maxseq()               { file_not_contains 'MAX\(aggregate_sequence\)' "$REPO"; }              # NEGATIVE: no MAX+1
check_C_sequential_loop()         { file_not_contains 'parallelStream' "$DISP"; }                          # NEGATIVE: stays sequential

# ── Fix D — cross-tick NOT EXISTS gate, fail-closed (includes FAILED_TERMINAL) ──
check_D_not_exists_gate()         { file_contains 'NOT EXISTS' "$REPO" && file_contains 'e\.id +< +o\.id' "$REPO"; }
check_D_fail_closed()             { file_contains "FAILED_TERMINAL" "$REPO"; }

# ── Fix E — unify all 3 club Phase-4 notifications; retire deprecated dispatchers ──
check_E_phase4_release_gone()     { file_not_contains 'customerOrderReleaseForPicking' "$CBATCH"; }        # NEGATIVE
check_E_phase4_started_gone()     { file_not_contains 'manageOrderService\.customerOrderPickingStarted' "$CBATCH"; }  # NEGATIVE
check_E_phase4_picked_gone()      { file_not_contains 'manageOrderService\.customerOrderPicked' "$CBATCH"; }          # NEGATIVE
check_E_finalize_enqueues()       { file_contains 'outboxService\.enqueue' "$CBATCH"; }                    # POSITIVE
check_E_dispatchers_retired()     { file_not_contains 'public +void +customerOrder(ReleaseForPicking|PickingStarted|Picked)\b' "$MANAGE"; }  # NEGATIVE: all 3 retired

# ── Fix F — event_version injected at dispatch; primary backward guard ──
check_F_event_version_inject()    { file_contains 'event_version|eventVersion' "$DISP"; }                  # POSITIVE (dispatcher-side)
check_F_backward_guard()          { file_contains 'pickingconfirmationsent|State\.PICKED' "$PICK"; }       # POSITIVE

echo
echo "verify-SBDEV-2381 — running acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

run A1   "A — V2.1.14 migration exists"                 check_A_migration_exists
run A2   "A — CREATE INDEX CONCURRENTLY present"        check_A_concurrently
run A3   "A — flyway:executeInTransaction=false"        check_A_non_transactional
run A4   "A — DROP INDEX IF EXISTS guard (rerun-safe)"  check_A_drop_guard
run A5   "A — no synthetic aggregate_sequence column"   check_A_no_column
echo
run B1   "B — no aggregateSequence entity field"        check_B_no_seq_field
echo
run C1   "C — claim ORDER BY next_attempt_at, id"       check_C_claim_order_by_id
run C2   "C — in-batch sort with getId tiebreak"        check_C_inbatch_sort
run C3   "C — no MAX(aggregate_sequence) read"          check_C_no_maxseq
run C4   "C — dispatch stays sequential (no parallel)"  check_C_sequential_loop
echo
run D1   "D — cross-tick NOT EXISTS gate keyed on id"   check_D_not_exists_gate
run D2   "D — fail-closed incl FAILED_TERMINAL"         check_D_fail_closed
echo
run E1   "E — Phase-4 RELEASE call removed"             check_E_phase4_release_gone
run E2   "E — Phase-4 STARTED call removed"             check_E_phase4_started_gone
run E3   "E — Phase-4 PICKED call removed"              check_E_phase4_picked_gone
run E4   "E — finalizeClubLine enqueues to outbox"      check_E_finalize_enqueues
run E5   "E — 3 deprecated dispatchers retired"         check_E_dispatchers_retired
echo
run F1   "F — event_version injected at dispatch"       check_F_event_version_inject
run F2   "F — backward guard on STARTED enqueue"        check_F_backward_guard
echo

# ── Behavioral checks (AC mapping in plan §8) — tests authored by wms-tdd-gate, now exercised ──
run AC1   "AC-1/8 dispatch sorts STARTED before FINISHED"  mvn_test_passes OutboxDispatchServiceUnitTest
run AC4   "AC-4 confirmPick skips STARTED when picked"     mvn_test_passes PickingorderBusinessServiceUnitTest
run AC5   "AC-5/15 club emits RELEASE->STARTED->FINISHED"  mvn_test_passes CustomerorderBatchServiceUnitTest
run AC15b "AC-15 historytote UUID stable / write once"     mvn_test_passes ManageOrderServiceUnitTest
run AC3   "AC-3/10 cross-tick gate holds higher-id row"    mvn_verify_passes OutboxClaimOrderingIT
run AC11  "AC-11 race-free concurrent enqueue + id-order"  mvn_verify_passes OutboxConcurrentEnqueueIT
run AC12  "AC-12/13 terminal hold + no leak/no stall"      mvn_verify_passes OutboxTerminalHoldIT
run AC14  "AC-14 EXPLAIN uses aggregate_order index"       mvn_verify_passes OutboxClaimExplainIT
run AC16  "AC-16 V2.1.14 applies + rerun-idempotent"       mvn_verify_passes OutboxMigrationV1124IT

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
