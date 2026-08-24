#!/usr/bin/env bash
# verify-SBDEV-2736-outbox-dispatcher-status-blind-rejection.sh   [revision 2]
#
# Machine-checkable acceptance for SBDEV-2736 Phase 1 — "outbox dispatcher is
# Status-blind: OMS rejections recorded as successful deliveries".
#
# Plan:   sbdocs/1-Projects/wms2/plan/SBDEV-2736-outbox-dispatcher-status-blind-rejection.md
# Ticket: https://app.clickup.com/t/868kgmr5a
#
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2736-outbox-dispatcher-status-blind-rejection.sh
#   $ RUN_TESTS=1 bash .../verify-SBDEV-2736-...sh      # include the Maven suites
#
# Exit 0 iff every check passes.
#
# ---------------------------------------------------------------------------
# PHASE-1 CONTRACT — read before editing.
#
# Phase 1 is BEHAVIOURALLY INERT: it adds two counters and a WARN log and
# changes NO delivery semantics. The P1-* checks therefore assert that
# markSent / outcome="sent" / writeServiceLog(SENT) are STILL PRESENT. Those
# are not leftovers to clean up — removing them is the Phase 2 change and must
# not happen here. When Phase 2 lands it gets its own verify script rather than
# editing this one.
#
# REVISION 2 (post-ralplan review) changed:
#   - detector is now a THREE-WAY classifier over TWO envelope shapes. A
#     root-only check misses 37.5% of real rejections (shape (b), the wrapped
#     {"status":"success","data":{"Status":"Error"}} form) and reports zero for
#     the entire picking family. E-wrapped is the check that pins this.
#   - r1's check_E_lowercase_test asserted the BUG as intended behavior and has
#     been deleted.
#   - the C-* sysprop-constant checks are gone: Fix C deferred to Phase 2.
#   - fail-open must catch Exception, not JsonProcessingException — dispatchOne's
#     outer catch(Exception) at ~:152 calls markRetry/markTerminal, so a stray
#     throwable would convert an OMS-accepted message into a delivery failure.
# ---------------------------------------------------------------------------

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
SBDOCS="${SBDOCS:-/home/nampark/dev/wms-claude/sbdocs}"
RUN_TESTS="${RUN_TESTS:-0}"

cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then printf "  PASS  %-12s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else printf "  FAIL  %-12s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi
}
skip() { printf "  SKIP  %-12s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

file_contains()     { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2" 2>/dev/null; }
# Whole-file PCRE, for anchoring a pattern INSIDE a specific method body.
# withEventVersion() already uses readTree/ObjectNode, so unanchored greps
# would pass before the classifier is written.
file_contains_ml()  { grep -Pzoq "$1" "$2" 2>/dev/null; }

CLASSIFIER=src/main/java/net/aim_ai/wms/service/OmsResponseClassifier.java
DISPATCH=src/main/java/net/aim_ai/wms/service/job/OutboxDispatchService.java
NOTIFY=src/main/java/net/aim_ai/wms/service/OmsNotificationService.java
EXPORTJOB=src/main/java/net/aim_ai/wms/schedulejob/StockSummaryExportJob.java
TEST=src/test/java/net/aim_ai/wms/unit/service/job/OutboxDispatchServiceUnitTest.java
CTEST=src/test/java/net/aim_ai/wms/unit/service/OmsResponseClassifierUnitTest.java
B2TEST=src/test/java/net/aim_ai/wms/unit/service/OmsNotificationServiceUnitTest.java
B3TEST=src/test/java/net/aim_ai/wms/unit/schedulejob/StockSummaryExportJobUnitTest.java
MIGDIR=src/main/resources/db/migration
DOCS="$SBDOCS/3-Resources/architecture/wms2-oms-integration-map.md"

# --- Fix A: three-way classifier, SHARED COMPONENT (r3) ----------------------
check_A_file()       { [ -f "$CLASSIFIER" ]; }
check_A_component()  { file_contains '@Component|@Service' "$CLASSIFIER"; }
check_A_enum()       { file_contains 'enum OmsVerdict' "$CLASSIFIER"; }
check_A_enum_vals()  { file_contains 'UNRECOGNIZED' "$CLASSIFIER"; }
check_A_method()     { file_contains 'public OmsVerdict classify\(String' "$CLASSIFIER"; }
check_A_field()      { file_contains 'OMS_STATUS_FIELD\s*=\s*"Status"' "$CLASSIFIER"; }
check_A_success()    { file_contains 'OMS_STATUS_SUCCESS\s*=\s*"Success"' "$CLASSIFIER"; }
# Shape (b): must look under a "data" wrapper. THE r1 BUG FIX.
check_A_wrapper()    { file_contains 'OMS_WRAPPER_DATA\s*=\s*"data"' "$CLASSIFIER"; }
check_A_two_level()  { file_contains_ml 'classify\(String[\s\S]{0,2500}?OMS_WRAPPER_DATA' "$CLASSIFIER"; }
# Fail-open MUST be catch(Exception), not JsonProcessingException.
check_A_failopen()   { file_contains_ml 'catch \(Exception[\s\S]{0,200}?UNRECOGNIZED' "$CLASSIFIER"; }
check_A_not_narrow() { file_not_contains 'catch \(JsonProcessingException' "$CLASSIFIER"; }
check_A_negspace()   { file_contains 'OMS_STATUS_SUCCESS\.equalsIgnoreCase' "$CLASSIFIER"; }
# --- r5: shape (c) + the per-record-failure downgrade -------------------------
# These exist because the r4 implementation scored 57/0 while classifying live partial failures as
# ACCEPTED — the gate could not tell the fixed build from the one that reported zero export rejections.
check_A_shapec()     { file_contains 'LOWERCASE_ACCEPTED_VERDICTS' "$CLASSIFIER"; }
check_A_shapec_list(){ file_contains 'Set\.of\("success", "exported"\)' "$CLASSIFIER"; }
check_A_perrecord()  { file_contains 'OMS_RECORDS_FAILED.*=.*"records_failed"' "$CLASSIFIER" \
                          && file_contains 'OMS_FAILED_RECORDS.*=.*"failed_records"' "$CLASSIFIER"; }
# The downgrade must be REACHABLE from classify(), not merely defined.
check_A_downgrade()  { file_contains 'hasPerRecordFailures\(data\) \? OmsVerdict\.REJECTED' "$CLASSIFIER"; }
# Applied to the capital-S success branch too, so an envelope convergence cannot re-open the hole.
check_A_uniform()    { file_contains 'hasPerRecordFailures\(root\) \|\| hasPerRecordFailures\(data\)' "$CLASSIFIER"; }
# Lenient field typing — PHP emits "1" for a count and an object for a re-keyed array.
check_A_lenient()    { file_contains 'asLong\(0\)' "$CLASSIFIER" \
                          && file_contains 'isContainerNode\(\)' "$CLASSIFIER"; }
check_A_trim()       { file_contains 'asText\(\)\.trim\(\)' "$CLASSIFIER"; }
check_A_objectnode() { file_contains 'instanceof ObjectNode' "$CLASSIFIER"; }
# Must NOT be duplicated back into the dispatcher.
check_A_notdup()     { file_not_contains 'enum OmsVerdict' "$DISPATCH"; }

# --- Fix B1: outbox dispatcher ----------------------------------------------
check_B_invoked()   { file_contains 'omsResponseClassifier\.classify\(|classifier\.classify\(' "$DISPATCH"; }
check_B_injected()  { file_contains 'OmsResponseClassifier' "$DISPATCH"; }

# --- Fix B2/B3: the other two egress paths (r3 scope widening) --------------
# These carry 95.5% of production rejection volume — see plan §0.3.
check_B2_notify()   { file_contains 'OmsResponseClassifier|\.classify\(' "$NOTIFY"; }
check_B2_counter()  { file_contains 'wms2\.oms\.notification\.rejected' "$NOTIFY"; }
check_B3_export()   { file_contains 'OmsResponseClassifier|\.classify\(' "$EXPORTJOB"; }
check_B3_counter()  { file_contains 'wms2\.oms\.export_rejected' "$EXPORTJOB"; }
# B3 inertness: the hard-coded SENT write must survive.
check_B3_still_sent() { file_contains 'MessageStatus\.SENT' "$EXPORTJOB"; }
check_B_rejected()  { file_contains 'wms2\.outbox\.oms_rejected' "$DISPATCH"; }
check_B_envelope()  { file_contains 'wms2\.outbox\.response_envelope' "$DISPATCH"; }
check_B_recognized(){ file_contains '"recognized"' "$DISPATCH"; }
check_B_tenant_tag(){ file_contains_ml 'Tags\.of\("tenant"[\s\S]{0,200}?"facility"' "$DISPATCH"; }
check_B_warn()      { file_contains 'LOG\.warn\("outboxDispatcher: OMS rejected' "$DISPATCH"; }
# Phase 1 must NOT escalate to ERROR (see plan Q2) nor repurpose the outcome tag.
check_B_not_error() { file_not_contains 'LOG\.error\("outboxDispatcher: OMS' "$DISPATCH"; }
check_B_no_reuse()  { file_not_contains 'TAG_OUTCOME,\s*"rejected"' "$DISPATCH"; }
# Fix C is deferred — the sysprop name must not appear at all (incl. comments).
check_B_no_sysprop(){ file_not_contains 'OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED' "$DISPATCH"; }

# --- Phase-1 inertness: delivery semantics unchanged ------------------------
check_P1_marksent()  { file_contains 'outboxService\.markSent\(msg\.getId\(\)\)' "$DISPATCH"; }
check_P1_sent_ctr()  { file_contains 'TAG_OUTCOME,\s*"sent"' "$DISPATCH"; }
check_P1_svclog()    { file_contains 'writeServiceLog\(msg,\s*WmsConstants\.MessageStatus\.SENT' "$DISPATCH"; }
check_P1_isterm()    { file_contains 'statusCode == 400 \|\| statusCode == 404 \|\| statusCode == 422' "$DISPATCH"; }
# No Phase-2 leakage: the 2xx path must not reach markTerminal/markRetry.
check_P1_no_term()   { file_not_contains 'REJECTED[\s\S]{0,200}?markTerminal' "$DISPATCH"; }

# --- Fix D: Flyway seed ------------------------------------------------------
check_D_file()      { ls "$MIGDIR"/V2.2.05__*.sql >/dev/null 2>&1; }
check_D_key()       { grep -qE "OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED" "$MIGDIR"/V2.2.05__*.sql 2>/dev/null; }
check_D_false()     { grep -qE "'false'" "$MIGDIR"/V2.2.05__*.sql 2>/dev/null; }
check_D_idem()      { grep -qiE "WHERE NOT EXISTS" "$MIGDIR"/V2.2.05__*.sql 2>/dev/null; }
# V2.2.04 includes a workstation column; r1's draft SQL omitted it.
check_D_workstation(){ grep -qE "workstation" "$MIGDIR"/V2.2.05__*.sql 2>/dev/null; }

# --- Fix E: tests -------------------------------------------------------------
check_E_corpus()    { file_contains 'dispatchOne_capturedBodies_neverAlterDeliveryOutcome' "$TEST"; }
check_E_raw()       { file_contains 'dispatchOne_2xxRawStatusError_incrementsRejectedCounter' "$TEST"; }
check_E_wrapped()   { file_contains 'dispatchOne_2xxWrappedDataStatusError_incrementsRejectedCounter' "$TEST"; }
check_E_success()   { file_contains 'dispatchOne_2xxStatusSuccess_bothShapes_doesNotIncrementRejectedCounter' "$TEST"; }
check_E_partial()   { file_contains 'dispatchOne_2xxPartiallyFailed_incrementsRejectedCounter' "$TEST"; }
check_E_unrecog()   { file_contains 'dispatchOne_2xxUnrecognizedBody_incrementsRecognizedNoAndNotRejected' "$TEST"; }
check_E_throws()    { file_contains 'dispatchOne_classifierThrowsRuntimeException_stillMarksSentAndNeverRetries' "$TEST"; }
check_E_tags()      { file_contains 'dispatchOne_rejectedCounter_isTaggedWithTenantAndFacility' "$TEST"; }
# Count @ParameterizedTest too. The r2 form counted only '@Test' and so under-reported by 3 once
# the corpus/shape cases were table-driven — a parameterized case is a test method, not a comment.
check_E_count()     { [ "$(grep -cE '@Test|@ParameterizedTest' "$TEST")" -ge 18 ]; }
check_E_orig()      { file_contains 'dispatchBatch_2xxResponse_createsMessageLogWithSentStatus' "$TEST"; }
# The corpus test must actually feed a wrapped body, not just be named for one.
check_E_real_body() { file_contains '"data":\{"Status":"Error"|\\"data\\":\{\\"Status\\"' "$TEST"; }
# r1's test pinned the bug — it must be GONE.
check_E_bug_gone()  { file_not_contains 'dispatchOne_2xxWithStatusErrorLowercaseKey_doesNotIncrementRejectedCounter' "$TEST"; }
# Inertness proof: never() assertions on the failure paths.
check_E_never()     { file_contains 'never\(\)\)\.markRetry|never\(\)\)\.markTerminal' "$TEST"; }
# r3: classifier gets its own test class owning the shape matrix.
check_E_ctest()        { [ -f "$CTEST" ]; }
# r5: the shape-(c) partial-failure case, and coverage on the two wiring sites that had none.
check_E_cpartial()   { file_contains 'classify_shapeC_withFailedRecords_isRejected' "$CTEST"; }
check_E_cfixture()   { file_contains 'records_failed\\":1' "$CTEST"; }
check_E_b2()         { file_contains 'notification\.rejected' "$B2TEST"; }
# @InjectMocks silently injected null before this — the tests were green over an unexercised feature.
check_E_b2spy()      { file_contains '@Spy' "$B2TEST"; }
check_E_b3()         { file_contains 'wms2\.oms\.export_rejected|exportRejectedCount' "$B3TEST"; }
check_E_b3partial()  { file_contains 'sendList_shapeCPartialFailure_incrementsExportRejectedCounter' "$B3TEST"; }
# The escaped alternative in r2 was wrong: it allowed an optional backslash before {"Status" but
# required an UNescaped closing quote, so it never matched a real Java string literal. Fixtures are
# written as "\"data\":{\"Status\":\"Error\"" — every inner quote is escaped.
check_E_ctest_shapes() { file_contains '"data":\{"Status"|\\"data\\":\{\\"Status\\"' "$CTEST"; }

# --- Fix F: docs --------------------------------------------------------------
check_F_ticket()    { file_contains 'SBDEV-2736' "$DOCS"; }
check_F_shapes()    { file_contains 'legacySuccessResponse|wrapped' "$DOCS"; }
# Assert a date AT OR AFTER the plan date, not merely "not the old one" —
# r1's negative check passed if last_verified were deleted or moved backwards.
check_F_verified()  { grep -qE 'last_verified: 2026-(0[7-9]|1[0-2])-|last_verified: 202[7-9]-' "$DOCS"; }

# --- Maven (opt-in) -----------------------------------------------------------
check_T_dispatch()  { mvn test -Dtest=OutboxDispatchServiceUnitTest -DfailIfNoTests=false 2>&1 \
                        | grep -qE "Tests run: [1-9][0-9]*, Failures: 0, Errors: 0"; }
check_T_job()       { mvn test -Dtest=OutboxDispatcherJobUnitTest -DfailIfNoTests=false 2>&1 \
                        | grep -qE "Tests run: [1-9][0-9]*, Failures: 0, Errors: 0"; }

echo
echo "verify-SBDEV-2736-outbox-dispatcher-status-blind-rejection [r2] — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

run A-file       "A — OmsResponseClassifier.java exists"             check_A_file
run A-bean       "A — is a Spring component"                         check_A_component
run A-enum       "A — OmsVerdict enum exists"                        check_A_enum
run A-enumvals   "A — enum has UNRECOGNIZED (three-way)"             check_A_enum_vals
run A-method     "A — public classify(String) exists"                check_A_method
run A-field      "A — OMS_STATUS_FIELD = \"Status\""                 check_A_field
run A-success    "A — OMS_STATUS_SUCCESS = \"Success\""              check_A_success
run A-wrapper    "A — OMS_WRAPPER_DATA = \"data\" (shape b)"         check_A_wrapper
run A-twolevel   "A — classifier reads the data wrapper"             check_A_two_level
run A-failopen   "A — catch(Exception) -> UNRECOGNIZED"              check_A_failopen
run A-notnarrow  "A — did NOT catch only JsonProcessingException"    check_A_not_narrow
run A-negspace   "A — matches NOT-Success, not ==\"Error\""          check_A_negspace
run A-trim       "A — trims the verdict before comparing"            check_A_trim
run A-shapec     "A — shape (c) lowercase accept-list (r5)"          check_A_shapec
run A-shapeclist "A — accept-list is {success, exported}"            check_A_shapec_list
run A-perrecord  "A — records_failed/failed_records constants"       check_A_perrecord
run A-downgrade  "A — shape (c) downgrades to REJECTED on failures"  check_A_downgrade
run A-uniform    "A — downgrade applies to (a)/(b) success too"      check_A_uniform
run A-lenient    "A — lenient field typing (asLong/isContainerNode)" check_A_lenient
run A-objnode    "A — requires ObjectNode at root"                   check_A_objectnode
run A-notdup     "A — not duplicated into the dispatcher"            check_A_notdup
echo
run B-invoked    "B1 — classifier invoked in dispatchOne"            check_B_invoked
run B-injected   "B1 — classifier injected"                          check_B_injected
run B2-notify    "B2 — OmsNotificationService classifies (r3)"       check_B2_notify
run B2-counter   "B2 — notification.rejected counter"                check_B2_counter
run B3-export    "B3 — StockSummaryExportJob classifies (r3)"        check_B3_export
run B3-counter   "B3 — export_rejected counter"                      check_B3_counter
run B3-sent      "B3 — still writes MessageStatus.SENT (inertness)"  check_B3_still_sent
run B-rejected   "B — wms2.outbox.oms_rejected counter"              check_B_rejected
run B-envelope   "B — wms2.outbox.response_envelope counter"         check_B_envelope
run B-recognized "B — recognized tag present"                        check_B_recognized
run B-tenant     "B — counters tagged tenant + facility"             check_B_tenant_tag
run B-warn       "B — WARN log on rejection"                         check_B_warn
run B-noterror   "B — did NOT use ERROR in Phase 1"                  check_B_not_error
run B-noreuse    "B — did NOT repurpose outcome=\"rejected\""        check_B_no_reuse
run B-nosysprop  "B — sysprop name absent (Fix C deferred)"          check_B_no_sysprop
echo
run P1-sent      "P1 — markSent STILL called (inertness)"            check_P1_marksent
run P1-counter   "P1 — outcome=\"sent\" STILL incremented"           check_P1_sent_ctr
run P1-svclog    "P1 — service log STILL written as SENT"            check_P1_svclog
run P1-isterm    "P1 — isTerminal policy untouched"                  check_P1_isterm
run P1-noterm    "P1 — no markTerminal on the rejection path"        check_P1_no_term
echo
run D-file       "D — V2.2.05 migration present"                     check_D_file
run D-key        "D — migration seeds the sysprop key"               check_D_key
run D-false      "D — seeded value is 'false'"                       check_D_false
run D-idem       "D — idempotent (WHERE NOT EXISTS)"                 check_D_idem
run D-workstn    "D — includes workstation column (cf V2.2.04)"      check_D_workstation
echo
run E-corpus     "E1 — captured-body corpus inertness test"          check_E_corpus
run E-raw        "E2 — shape (a) raw Status:Error test"              check_E_raw
run E-wrapped    "E3 — shape (b) wrapped data.Status test"           check_E_wrapped
run E-success    "E4 — Status:Success both shapes test"              check_E_success
run E-partial    "E5 — Partially Failed test"                        check_E_partial
run E-unrecog    "E6 — unrecognized body test"                       check_E_unrecog
run E-throws     "E7 — classifier-throws fail-open test"             check_E_throws
run E-tags       "E8 — tenant/facility tag test"                     check_E_tags
run E-realbody   "E  — a real wrapped body appears in fixtures"      check_E_real_body
run E-never      "E  — never() assertions on markRetry/markTerminal" check_E_never
run E-buggone    "E  — r1 bug-pinning lowercase test REMOVED"        check_E_bug_gone
run E-count      "E  — >=18 @Test methods (10 existing + 8 new)"     check_E_count
run E-orig       "E  — original 2xx smoke test still present"        check_E_orig
run E-ctest      "E  — OmsResponseClassifierUnitTest exists (r3)"    check_E_ctest
run E-cshapes    "E  — classifier test covers both shapes"           check_E_ctest_shapes
run E-cpartial   "E  — shape (c) partial-failure test (r5)"          check_E_cpartial
run E-cfixture   "E  — a real records_failed body is a fixture"      check_E_cfixture
run E-b2         "E  — Fix B2 has rejection coverage (r5)"           check_E_b2
run E-b2spy      "E  — B2 test injects a REAL classifier, not null"  check_E_b2spy
run E-b3         "E  — Fix B3 has rejection coverage (r5)"           check_E_b3
run E-b3partial  "E  — B3 test covers the shape (c) partial case"    check_E_b3partial
echo
run F-ticket     "F — integration map mentions SBDEV-2736"           check_F_ticket
run F-shapes     "F — documents both envelope shapes"                check_F_shapes
run F-verified   "F — last_verified >= 2026-07"                      check_F_verified
echo

if [ "$RUN_TESTS" = "1" ]; then
    run T-dispatch "T — OutboxDispatchServiceUnitTest passes"        check_T_dispatch
    run T-job      "T — OutboxDispatcherJobUnitTest passes"          check_T_job
else
    skip T-tests  "T — Maven suites"                                 "set RUN_TESTS=1 to run"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
