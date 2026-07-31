#!/usr/bin/env bash
# verify-SBDEV-2778-return-to-inventory-not-received-bol-not-closed.sh
#
# Machine-checkable acceptance for
#   sbdocs/1-Projects/wms2/plan/SBDEV-2778-return-to-inventory-not-received-bol-not-closed.md
#
# SBDEV-2778 — "Return to Inventory" creates a RETURN inbound advice (BOL) that is never
# received and never closed. The fix re-introduces auto-receive GATED on an explicit
# `qa_confirmed` assertion from OMS, so SBDEV-2236's invariant (physical confirmation must
# precede the WMS stock increment) is preserved rather than reverted.
#
# Usage:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2778-return-to-inventory-not-received-bol-not-closed.sh
#
#   # with the OMS repo checked in a non-default location, and including the slow mvn check:
#   $ OMS_ROOT=/path/to/oms-laravel-api RUN_MVN=1 bash sbdocs/9-System/scripts/verify-SBDEV-2778-*.sh
#
# Exit code 0 only when every check passes. Paste the final `Result:` line into the plan's §11.
#
# IMPORTANT — negative-test this script before trusting it. A "N pass, 0 fail" means nothing
# until you have replayed the PRE-FIX files and watched it FAIL. `git stash` the change, run,
# confirm failures, then restore.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
OMS_ROOT="${OMS_ROOT:-/home/nampark/dev/wms-claude/v2/oms-laravel-api}"
RUN_MVN="${RUN_MVN:-0}"

cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1))
}

file_contains()     { [ -f "$2" ] && grep -qE "$1" "$2" 2>/dev/null; }
# Fail closed: grep exits 2 on a missing file, which `!` would flip into a false PASS.
file_not_contains() { [ -f "$2" ] && ! grep -qE "$1" "$2" 2>/dev/null; }
# Multi-line variant — perl -0777 so the regex may span newlines.
# CRITICAL — every helper must FAIL CLOSED on a missing/unreadable file.
#
# With `perl -0777 -ne`, a file that cannot be opened means the implicit loop body never
# executes, so neither `exit 0` nor `exit 1` runs and perl terminates with status 0. Without
# the explicit `-f` guard below, every multi-line assertion PASSES against a file that does
# not exist — a false green that hides an entirely unimplemented fix. This was caught by
# negative-testing this script against the pre-fix tree; do not remove the guards.
file_contains_ml() {
    [ -f "$2" ] || return 1
    PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null
}
# NOTE: a missing file must FAIL here too. "The old construct is absent because the file is
# absent" is not evidence that anything was implemented.
file_not_contains_ml() {
    [ -f "$2" ] || return 1
    ! PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null
}
# Match a regex on at least N lines of a file.
file_contains_n_times() {
    [ -f "$2" ] || return 1
    local count
    count=$(grep -cE "$1" "$2" 2>/dev/null || echo 0)
    [ "$count" -ge "$3" ]
}
# Multi-line regex with /s (dot matches newline) — for "X appears before Y" ordering.
file_contains_ordered() {
    [ -f "$2" ] || return 1
    PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/s; exit 1' "$2" 2>/dev/null
}
file_not_contains_ordered() {
    [ -f "$2" ] || return 1
    ! PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/s; exit 1' "$2" 2>/dev/null
}
mvn_test_passes() {
    mvn test -Dtest="$1" -DfailIfNoTests=false -q 2>&1 \
        | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0"
}

CTRL=src/main/java/net/aim_ai/wms/controller/rest/AdviceRestController.java
DTO=src/main/java/net/aim_ai/wms/json/AdviceDto.java
SVC=src/main/java/net/aim_ai/wms/service/ReturnAdviceAutoReceiveService.java
CONST=src/main/java/net/aim_ai/wms/service/WmsConstants.java
RECV=src/main/java/net/aim_ai/wms/service/ReceivingService.java
CTRL_TEST=src/test/java/net/aim_ai/wms/unit/controller/rest/AdviceRestControllerUnitTest.java
SVC_TEST=src/test/java/net/aim_ai/wms/unit/service/ReturnAdviceAutoReceiveServiceUnitTest.java
OMS_QA="$OMS_ROOT/app/Services/Qa/QaReturnService.php"

echo
echo "verify-SBDEV-2778 — Return-to-Inventory auto-receive (QA-gated) acceptance"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  OMS_ROOT=$OMS_ROOT"
echo

# --- Fix A — the qa_confirmed contract field ---------------------------------

run A1 "Fix A — AdviceDto declares @JsonProperty(\"qa_confirmed\")" \
    file_contains_ml '@JsonProperty\("qa_confirmed"\)\s*\n\s*private\s+Boolean\s+qaConfirmed' "$DTO"
run A2 "Fix A — AdviceDto exposes getQaConfirmed()" \
    file_contains 'public\s+Boolean\s+getQaConfirmed\s*\(' "$DTO"
run A3 "Fix A — AdviceDto exposes setQaConfirmed()" \
    file_contains 'public\s+void\s+setQaConfirmed\s*\(\s*Boolean' "$DTO"
# A1 already pins the boxed `Boolean` declaration, which is what makes absent and
# explicit-false both representable. A separate "not primitive" negative check would pass
# vacuously while the field is missing entirely, so it is deliberately omitted.

echo

# --- Fix B — ReturnAdviceAutoReceiveService ----------------------------------

run B1 "Fix B — ReturnAdviceAutoReceiveService exists" \
    test -f "$SVC"
# B2a — the DB-read step carries the read-only tenant tx; validate() itself must NOT, so the CUPS
# probe runs outside the transaction (otherwise we reproduce the ReceivingService:315 anti-pattern
# one level up). Assert both directions.
run B2 "Fix B0 — the resolve step is a READ-ONLY tenant transaction" \
    file_contains_ml '@Transactional\(\s*value\s*=\s*"tenantTransactionManager"\s*,\s*readOnly\s*=\s*true\s*\)\s*\n\s*\w+\s+\w+\s+resolveRefs' "$SVC"
run B2b "Fix B2a — validate() itself is NOT transactional (CUPS probe outside the tx)" \
    file_not_contains_ml '@Transactional[^\n]*\n\s*public\s+\w+\s+validate\s*\(' "$SVC"
run B3 "Fix B — execute() exists" \
    file_contains 'public\s+void\s+execute\s*\(' "$SVC"
# execute() must NOT be transactional: wrapping it would hold one tenant connection
# across all N CUPS round-trips (ReceivingService:315).
run B4 "Fix B — execute() is NOT annotated @Transactional" \
    file_not_contains_ml '@Transactional[^\n]*\n\s*public\s+void\s+execute\s*\(' "$SVC"

run B5 "Fix B — printer resolution honors the caller-supplied printerId first" \
    file_contains 'findById\(\s*requestedPrinterId\s*\)' "$SVC"
run B6 "Fix B — falls back to the processdefault RETURN printer" \
    file_contains 'findByTypeAndProcessdefaultTrue\(\s*WmsConstants\.PrinterType\.RETURN\s*\)' "$SVC"
run B7 "Fix B — THROWS when no printer resolves (no silent v1-style skip)" \
    file_contains_ml 'findByTypeAndProcessdefaultTrue\([^)]*\)\s*\n?\s*\.orElseThrow' "$SVC"
run B8 "Fix B — rejects a printerId whose type is not RETURN" \
    file_contains_ml 'PrinterType\.RETURN\.equals\(\s*\w+\.getType\(\)\s*\)' "$SVC"
# Boxtype: validate() must resolve the SAME boxtype the save loop will persist, via the same
# lookup the loop uses (AdviceRestController:247), so the two cannot disagree.
#
# Deliberately NOT asserted: getDefaultboxtypeId() / SYSTEM_PROPERTY_DEFAULT_BOX_TYPE_KEY.
# v1's three-step fallback chain is UNREACHABLE on the REST create path — AdviceRestController:262
# unconditionally sets boxtypeId from optionalBoxtype.get(), so boxtypeId is always populated by the
# time any RETURN block runs. Asserting the chain would force the implementer to add dead branches
# just to turn this script green. See plan §3 B2 and §10-Q10.
run B9 "Fix B — validate() resolves boxtype by the position's box_id (same lookup as :247)" \
    file_contains 'findByExternalid\(' "$SVC"
run B10 "Fix B — boxtype resolution failure throws (defensive orElseThrow)" \
    file_contains_ml 'findByExternalid\([^)]*\)\s*\n?\s*\.orElseThrow' "$SVC"
run B11 "Fix B — uses DEFAULT_TYPE_NOT_EXIST as the boxtype failure code" \
    file_contains 'DEFAULT_TYPE_NOT_EXIST' "$SVC"
run B12 "Fix B — calls receiveGoods with the 8-arg signature" \
    file_contains 'receivingService\.receiveGoods\(' "$SVC"
run B13 "Fix B — flips adviceposition rows to FINISHED" \
    file_contains 'updateAdvicepositionToStateByAdviceId\(\s*AdviceState\.FINISHED' "$SVC"
run B14 "Fix B — flips the advice to FINISHED" \
    file_contains 'updateAdviceToStateById\(\s*AdviceState\.FINISHED' "$SVC"
run B15 "Fix B — partial failure raises RETURN_AUTO_RECEIVE_PARTIAL" \
    file_contains 'RETURN_AUTO_RECEIVE_PARTIAL' "$SVC"
run B16 "Fix B — partial-failure log names the failing SKU" \
    file_contains 'failedSku' "$SVC"
# NOTE: B17 is WEAK, not sound. C8 pins exactly one receiveGoods call-site, so a FINISHED flip placed
# INSIDE the loop still appears after that single call and B17 still passes. There is no sound static
# check for the all-or-nothing invariant (§3 B3 / §8 AC2) — it is guarded by test T10 and by
# RUN_MVN=1 M2, not by grep. Kept as a cheap smoke check only.
run B17 "Fix B — receive loop precedes the FINISHED flips (all-or-nothing ordering)" \
    file_contains_ordered 'receivingService\.receiveGoods\(.*?updateAdvicepositionToStateByAdviceId' "$SVC"

echo

# --- Fix C — the gated call site in the controller ---------------------------

run C1 "Fix C — controller gates auto-receive on RETURN && qa_confirmed" \
    file_contains_ml 'AdviceType\.RETURN\.equals\([^)]*\)\s*\n?\s*&&\s*Boolean\.TRUE\.equals\(\s*adviceDto\.getQaConfirmed\(\)\s*\)' "$CTRL"
run C2 "Fix C — controller invokes validate() with the DTO" \
    file_contains 'returnAdviceAutoReceiveService\.validate\(\s*adviceDto\s*\)' "$CTRL"
run C3 "Fix C — controller invokes execute()" \
    file_contains 'returnAdviceAutoReceiveService\.execute\(' "$CTRL"
run C4 "Fix C — ReturnAdviceAutoReceiveService is constructor-injected" \
    file_contains_ml 'public\s+AdviceRestController\((?:[^)]*\n)*?[^)]*ReturnAdviceAutoReceiveService' "$CTRL"
run C5 "Fix C — the field is assigned in the constructor" \
    file_contains 'this\.returnAdviceAutoReceiveService\s*=' "$CTRL"

# R9 / ORDERING — the single most important structural assertion in this script.
# validate() MUST be invoked BEFORE adviceRepository.save(...). If it runs after, a rejected
# advice has already committed externalid=RETURN{parcel_id} and every OMS retry then dies on the
# duplicate guard at :139-142, leaving the return unmanageable. Ordered match proves the
# sequence, not merely the presence, of both calls.
run C6a "R9 — validate() appears before a save (necessary, NOT sufficient — see C6b)" \
    file_contains_ordered 'returnAdviceAutoReceiveService\.validate\(.*?adviceRepository\.save\(' "$CTRL"
# C6a alone false-positives: adviceRepository.save( occurs at :198, :369 (createTransfer) and :494
# (createHubAndSpoke), so a validate() placed AFTER :198 still matches against the :369 save under /s.
# save(adviceEntity) occurs exactly once (:198), so the negative direction is the sound assertion.
# Compound so it cannot pass vacuously: the validate() call must EXIST, and save(adviceEntity)
# must not precede it. A bare negative passes when validate() is absent entirely.
check_C6b() {
    file_contains 'returnAdviceAutoReceiveService\.validate\(' "$CTRL" \
        && file_not_contains_ordered 'adviceRepository\.save\(\s*adviceEntity\s*\).*?returnAdviceAutoReceiveService\.validate\(' "$CTRL"
}
run C6b "R9 — validate() exists AND save(adviceEntity) does not precede it (sound ordering)" \
    check_C6b

# ADJACENCY — the gate and the auto-receive calls must live in the same guarded block, not merely
# coexist in the file. Replaces the earlier `file_not_contains 'receivingService.receiveGoods('`
# check, which was VACUOUS: Fix B deliberately moves receiveGoods out of the controller, so the
# negative passed by construction whether or not the gate existed.
run C7 "Fix C — the qa_confirmed gate and validate() are adjacent (same guarded block)" \
    file_contains_ordered 'Boolean\.TRUE\.equals\(\s*adviceDto\.getQaConfirmed\(\)\s*\).{0,400}?returnAdviceAutoReceiveService\.validate\(' "$CTRL"
# Exactly one receiveGoods call-site in the service — proves the loop was not duplicated or
# accidentally left in the controller as well.
run C8 "Fix B — exactly ONE receiveGoods call-site in the service" \
    bash -c '[ "$(grep -cE "receivingService\.receiveGoods\(" '"$SVC"' 2>/dev/null || echo 0)" -eq 1 ]'
run C9 "Fix C — stale ':\''151-156'\'' comment refreshed to mention qa_confirmed" \
    file_contains 'qa_confirmed' "$CTRL"
# B2a — print availability asserted during validation, not only inside receiveGoods.
run C10 "Fix B2a — isPrintAvailable checked in the service (CUPS-down fails before any receive)" \
    file_contains 'isPrintAvailable\(' "$SVC"

echo

# --- Error code + operator-facing message ------------------------------------

run E1 "WmsConstants declares RETURN_AUTO_RECEIVE_PARTIAL" \
    file_contains 'RETURN_AUTO_RECEIVE_PARTIAL\s*=' "$CONST"
# Declaration + at least one switch arm => the constant is actually mapped to a message,
# not just declared and orphaned.
run E2 "RETURN_AUTO_RECEIVE_PARTIAL appears >=2x in WmsConstants (constant + switch arm)" \
    file_contains_n_times 'RETURN_AUTO_RECEIVE_PARTIAL' "$CONST" 2

echo

# --- Preserved invariants (SBDEV-2236 regression guards) --------------------

run G1 "SBDEV-2236 guard — unflagged-advice test still present" \
    file_contains 'shouldCreateReturnAdviceWithoutAutoReceive' "$CTRL_TEST"
# G2 REPLACED. The old check asserted the presence of `verify(receivingService, never()).receiveGoods`,
# which is TAUTOLOGICAL: AdviceRestControllerUnitTest keeps receivingService as an UNWIRED @Mock (see
# its comment at :58-59 — "controller no longer injects these") so it can never be called and the
# assertion can never fail. The real guard is a POSITIVE one: 2236's own checklist :309 specified
# asserting the advice is left in OPEN state. Assert that captor exists instead.
# File-wide grep for ArgumentCaptor/AdviceState.OPEN passes vacuously — the fixtures already contain
# 4 such matches. Anchor on the method name so the captor must appear INSIDE the unflagged test.
run G2 "SBDEV-2236 guard — unflagged test itself asserts state == OPEN (anchored, not file-wide)" \
    file_contains_ordered 'shouldCreateReturnAdviceWithoutAutoReceive.{0,3000}?AdviceState\.OPEN' "$CTRL_TEST"
run G3 "SBDEV-2236 guard — still asserts state is never set FINISHED" \
    file_contains 'never\(\)\)\.updateAdviceToStateById\(eq\(WmsConstants\.AdviceState\.FINISHED\)' "$CTRL_TEST"
# ReceivingService must not have been modified to hoist the CUPS check (that is a
# deliberate follow-up, §10-Q6 — flag it here so an unplanned change is visible).
run G4 "ReceivingService.receiveGoods still @Transactional(tenantTransactionManager)" \
    file_contains_ml '@Transactional\(value\s*=\s*"tenantTransactionManager"[^)]*\)\s*\n\s*public\s+void\s+receiveGoods' "$RECV"

# getErrorMap() must carry the code — §6.2 step 4, R1's hard prerequisite, previously unasserted.
run E3 "R1 prereq — getErrorMap() emits the error code" \
    file_contains 'put\("code"' src/main/java/net/aim_ai/wms/exceptions/WebserviceBusinessExceptionClientSide.java
run E4 "R1 prereq — getErrorMap() emits errorCodeName" \
    file_contains 'put\("errorCodeName"' src/main/java/net/aim_ai/wms/exceptions/WebserviceBusinessExceptionClientSide.java
run E5 "Fix B — bind() exists (validated -> persisted position ids)" \
    file_contains 'public\s+\w+\s+bind\s*\(' "$SVC"
run E6 "Observability — Micrometer counter registered (§6.1-9, §7 row 8)" \
    file_contains 'MeterRegistry|Counter\.builder|meterRegistry' "$SVC"

echo

# --- New tests exist --------------------------------------------------------

run T1 "Tests — ReturnAdviceAutoReceiveServiceUnitTest exists" \
    test -f "$SVC_TEST"
run T2 "Tests — flagged auto-receive case covered" \
    file_contains 'shouldAutoReceiveReturnAdviceWhenQaConfirmed' "$CTRL_TEST"
run T3 "Tests — advice marked FINISHED case covered" \
    file_contains 'shouldMarkReturnAdviceFinishedWhenQaConfirmed' "$CTRL_TEST"
run T4 "Tests — explicit qa_confirmed=false case covered" \
    file_contains 'shouldNotAutoReceiveWhenQaConfirmedIsFalse' "$CTRL_TEST"
run T5 "Tests — REGULAR advice unaffected by the flag" \
    file_contains 'shouldNotAutoReceiveRegularAdviceEvenWhenQaConfirmed' "$CTRL_TEST"
run T6 "Tests — explicit printerId honored" \
    file_contains 'shouldUseExplicitPrinterIdWhenQaConfirmed' "$CTRL_TEST"
run T7 "Tests — invalid printerId returns 400" \
    file_contains 'shouldReturn400WhenPrinterIdInvalidAndQaConfirmed' "$CTRL_TEST"
run T8 "Tests — no configured RETURN printer returns 400" \
    file_contains 'shouldReturn400WhenNoReturnPrinterConfiguredAndQaConfirmed' "$CTRL_TEST"
run T9 "Tests — multi-position advice covered" \
    file_contains 'shouldAutoReceiveAllPositionsOfMultiPositionReturnAdvice' "$CTRL_TEST"
run T10 "Tests — partial-failure case covered in the service test" \
    file_contains 'executeThrowsPartialFailureAndDoesNotMarkFinishedWhenSecondPositionFails' "$SVC_TEST"
run T11 "Tests — stale 'ignore printer_id' test removed or renamed" \
    file_not_contains 'shouldCreateReturnAdviceAndIgnorePrinterId' "$CTRL_TEST"

echo

# --- Fix D — OMS sets the assertion ----------------------------------------

if [ -f "$OMS_QA" ]; then
    run D1 "Fix D — OMS Flow-1 advice payload carries qa_confirmed => true" \
        file_contains "'qa_confirmed'\s*=>\s*true" "$OMS_QA"
    run D2 "Fix D — qa_confirmed sits in the sendReturnRestockAdvice payload block" \
        file_contains_ordered 'sendReturnRestockAdvice.*?qa_confirmed' "$OMS_QA"
else
    skip D1 "Fix D — OMS payload carries qa_confirmed" "OMS_ROOT not found: $OMS_ROOT"
    skip D2 "Fix D — qa_confirmed in sendReturnRestockAdvice" "OMS_ROOT not found: $OMS_ROOT"
fi

echo

# --- Targeted tests (slow; opt in with RUN_MVN=1) ---------------------------
# NOTE: `mvn test` MUTATES the tracked archunit_store — `git checkout` it afterwards.
# NOTE: clean-develop baseline is 2/4442 failing (OptionalSafetyArchTest,
#       MobilePalletizingServiceTest); those are NOT caused by this change.
# NOTE: AdviceRestControllerUnitTest uses @Nested — never use -Dtest='Outer#method',
#       it silently no-ops and reports a false green.

if [ "$RUN_MVN" = "1" ]; then
    run M1 "AdviceRestControllerUnitTest passes" mvn_test_passes AdviceRestControllerUnitTest
    run M2 "ReturnAdviceAutoReceiveServiceUnitTest passes" mvn_test_passes ReturnAdviceAutoReceiveServiceUnitTest
    run M3 "ReceivingControllerUnitTest passes (dock-receive regression)" mvn_test_passes ReceivingControllerUnitTest
else
    skip M1 "AdviceRestControllerUnitTest passes" "set RUN_MVN=1 to run"
    skip M2 "ReturnAdviceAutoReceiveServiceUnitTest passes" "set RUN_MVN=1 to run"
    skip M3 "ReceivingControllerUnitTest passes" "set RUN_MVN=1 to run"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
