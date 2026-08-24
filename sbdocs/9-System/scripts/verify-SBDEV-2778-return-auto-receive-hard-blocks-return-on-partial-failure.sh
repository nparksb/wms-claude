#!/usr/bin/env bash
# verify-SBDEV-2778-return-auto-receive-hard-blocks-return-on-partial-failure.sh   (rev3)
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2778-return-auto-receive-hard-blocks-return-on-partial-failure.md
#
# Two repos. Point PROJECT_ROOT at the monorepo root (or at a symlink shadow root
# whose v2/ children are the per-ticket worktrees — see wms-plan-executor):
#
#   $ PROJECT_ROOT=/home/nampark/dev/wms-claude \
#       bash sbdocs/9-System/scripts/verify-SBDEV-2778-return-auto-receive-hard-blocks-return-on-partial-failure.sh
#
# Override either repo with WMS_ROOT= / OMS_ROOT=. RUN_MVN=1 also runs the JUnit classes.
# Exit 0 iff every check passes. A "DONE" claim with FAIL lines is not accepted.
#
# rev2 (architect review): the resume fix was CUT (plan §5.6), so its assertions are gone and
# S4 now asserts it did NOT come back. F3 was re-grounded on a state probe, so its assertions
# target `diagnose(` and the two exception-reading traps. F2 gained the audit-row assertions.
#
# ─────────────────────────────────────────────────────────────────────────────
# ⚠ HELPER CONTRACT — read before adding a check
#
# 1. Every perl-based helper begins with `[ -f "$2" ] || return 1`. This is NOT
#    boilerplate: `perl -0777 -ne '...' missing.java` exits 0 when it cannot open
#    the file, so without it every multi-line assertion about a missing file
#    silently PASSES. Proven: unguarded -> exit 0, guarded -> exit 1.
#
# 2. Patterns reach perl through the ENVIRONMENT ($ENV{VP_P}), never interpolated
#    into the program text. A mis-escaped `\[` there yields "Unmatched [ in regex"
#    and perl exits 255, which a NEGATIVE assertion reads as "no match" — passing
#    for the wrong reason. That bit F6b during rev1 authoring.
#
# 3. Corollary of (2): never put a literal `$` in a pattern — perl reads it as an
#    anchor. Match a PHP variable as `.response`, not `$response`.
#
# 4. Every fix has a POSITIVE ("the new construct is at the right site") and a
#    NEGATIVE ("the old / unsafe construct is gone"). Negatives are written
#    against files that already exist, so none is vacuous.
# ─────────────────────────────────────────────────────────────────────────────

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude}"
WMS_ROOT="${WMS_ROOT:-$PROJECT_ROOT/v2/wms2-api}"
OMS_ROOT="${OMS_ROOT:-$PROJECT_ROOT/v2/oms-laravel-api}"
RUN_MVN="${RUN_MVN:-0}"

[ -d "$WMS_ROOT" ] || { echo "FATAL: WMS_ROOT=$WMS_ROOT not found"; exit 2; }
[ -d "$OMS_ROOT" ] || { echo "FATAL: OMS_ROOT=$OMS_ROOT not found"; exit 2; }

SVC="$WMS_ROOT/src/main/java/net/aim_ai/wms/service/ReturnAdviceAutoReceiveService.java"
CTRL="$WMS_ROOT/src/main/java/net/aim_ai/wms/controller/rest/AdviceRestController.java"
CONST="$WMS_ROOT/src/main/java/net/aim_ai/wms/service/WmsConstants.java"
RECV="$WMS_ROOT/src/main/java/net/aim_ai/wms/service/ReceivingService.java"
BEXC="$WMS_ROOT/src/main/java/net/aim_ai/wms/exceptions/BusinessException.java"
IDEMP="$WMS_ROOT/src/main/java/net/aim_ai/wms/service/RestIdempotencyService.java"
QARET="$OMS_ROOT/app/Services/Qa/QaReturnService.php"
WMSAPI="$OMS_ROOT/app/Services/WmsApiService.php"
MIGDIR="$WMS_ROOT/src/main/resources/db/migration"
OMSTEST="$OMS_ROOT/tests/Unit/Services/WmsApiServiceTest.php"
VAULT="${VAULT:-$PROJECT_ROOT/sbdocs}"
DOC_WORKFLOW="$VAULT/3-Resources/workflows/wms2-receiving-putaway-workflow.md"
DOC_STATEMACHINE="$VAULT/3-Resources/architecture/wms2-state-machine-catalog.md"
DOC_ARCHIVED="$VAULT/4-Archieves/wms2/plan/SBDEV-2778-return-to-inventory-not-received-bol-not-closed.md"

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
    local id=$1 desc=$2 reason=$3
    printf "  SKIP  %-10s  %s  (%s)\n" "$id" "$desc" "$reason"; SKIP=$((SKIP+1))
}

# --- assertion helpers (all guard on file existence FIRST) -------------------

file_contains() { [ -f "$2" ] || return 1; grep -qE "$1" "$2"; }

file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }

# NOTE: grep -cE counts matching LINES, not occurrences — two hits on one line
# would read as 1 and a single-reference assertion would pass with two references
# present. -oE emits one line per occurrence, which is what we actually mean.
file_contains_exactly_n() {
    local pattern=$1 file=$2 n=$3 count
    [ -f "$file" ] || return 1
    count=$(grep -oE "$pattern" "$file" 2>/dev/null | wc -l)
    [ "$count" -eq "$n" ]
}

file_contains_multiline() {
    [ -f "$2" ] || return 1
    VP_P="$1" perl -0777 -ne 'exit($_ =~ /$ENV{VP_P}/s ? 0 : 1)' "$2"
}

file_not_contains_multiline() {
    [ -f "$2" ] || return 1
    VP_P="$1" perl -0777 -ne 'exit($_ =~ /$ENV{VP_P}/s ? 1 : 0)' "$2"
}

# $1 must appear BEFORE $2, and both must appear.
vp_in_order() {
    local first=$1 second=$2 file=$3
    [ -f "$file" ] || return 1
    VP_A="$first" VP_B="$second" perl -0777 -ne '
        my ($a, $b) = ($ENV{VP_A}, $ENV{VP_B});
        exit(1) unless $_ =~ /$a/s;
        my $rest = substr($_, $-[0]);
        exit($rest =~ /$b/s ? 0 : 1);
    ' "$file"
}

# A regex must appear inside a named method body (window-scoped, far stronger
# than a file-wide grep). A MISSING method is a FAIL, never a free pass.
method_body_contains() {
    local method_sig=$1 pattern=$2 file=$3
    [ -f "$file" ] || return 1
    VP_M="$method_sig" VP_P="$pattern" perl -0777 -ne '
        my ($m, $p) = ($ENV{VP_M}, $ENV{VP_P});
        exit(1) unless $_ =~ /$m/s;
        my $body = substr($_, $-[0]);
        $body = substr($body, 0, 6000);
        exit($body =~ /$p/s ? 0 : 1);
    ' "$file"
}

method_body_not_contains() {
    local method_sig=$1 pattern=$2 file=$3
    [ -f "$file" ] || return 1
    VP_M="$method_sig" VP_P="$pattern" perl -0777 -ne '
        my ($m, $p) = ($ENV{VP_M}, $ENV{VP_P});
        exit(1) unless $_ =~ /$m/s;   # method missing => FAIL
        my $body = substr($_, $-[0]);
        $body = substr($body, 0, 6000);
        exit($body =~ /$p/s ? 1 : 0);
    ' "$file"
}

mvn_test_passes() {
    local test_class=$1
    [ -d "$WMS_ROOT" ] || return 1
    (cd "$WMS_ROOT" && mvn test -Dtest="$test_class" -DfailIfNoTests=false 2>&1 \
        | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0")
}

# === F1 — soft-fail: execute reports the outcome instead of throwing ==========

check_F1_execute_returns_outcome() {
    file_contains 'public\s+AutoReceiveOutcome\s+execute\s*\(\s*AutoReceivePlan' "$SVC"
}

check_F1_partial_outcome_returned() {
    method_body_contains 'AutoReceiveOutcome\s+executeInternal' \
        'return\s+AutoReceiveOutcome\.partial\s*\(' "$SVC"
}

# NEGATIVE — the whole point of the ticket. If the throw survives, the return is
# still blocked no matter what else shipped.
check_F1_partial_throw_gone() {
    file_not_contains_multiline \
        'throw\s+new\s+WebserviceBusinessExceptionClientSide\s*\(\s*\n?\s*WmsConstants\.RETURN_AUTO_RECEIVE_PARTIAL' \
        "$SVC"
}

check_F1_outcome_record_present() {
    file_contains 'record\s+AutoReceiveOutcome' "$SVC" \
        && file_contains 'enum\s+Status\s*\{\s*SUCCESS,\s*PARTIAL,\s*SKIPPED' "$SVC"
}

# === F1-regression — PR #123's guarantees survive ============================

check_F1r_markfinished_intact() {
    vp_in_order '@Transactional\(value\s*=\s*"tenantTransactionManager"\)' \
                'public\s+void\s+markFinished\s*\(\s*Long\s+adviceId' "$SVC" \
        && file_contains 'self\.markFinished\s*\(\s*plan\.adviceId\(\)\s*\)' "$SVC"
}

# NEGATIVE: markFinished must not be reachable from inside the catch block.
check_F1r_markfinished_not_in_catch() {
    file_not_contains_multiline \
        'catch\s*\(BusinessException\s*\|\s*FacadeException\s*\|\s*RuntimeException[^}]{0,4000}self\.markFinished' \
        "$SVC"
}

# NEGATIVE: execute() did not become @Transactional (plan §5.4 / original B2b).
check_F1r_execute_still_not_transactional() {
    # All THREE execute* methods must stay non-transactional (plan §5.4 / original
    # B2b): an @Transactional on any of them holds a tenant connection across every
    # CUPS round-trip and poisons the caught-failure path via rollbackFor.
    file_not_contains_multiline \
        '@Transactional[^\n]*\n\s*public\s+AutoReceiveOutcome\s+execute\s*\(' "$SVC" \
        && file_not_contains_multiline \
            '@Transactional[^\n]*\n\s*private\s+AutoReceiveOutcome\s+executeAsIntegrationUser\s*\(' "$SVC" \
        && file_not_contains_multiline \
            '@Transactional[^\n]*\n\s*private\s+AutoReceiveOutcome\s+executeInternal\s*\(' "$SVC"
}

# === F2 — 200-with-warning + the audit row ===================================

check_F2_outcome_captured() {
    file_contains 'ReturnAdviceAutoReceiveService\.AutoReceiveOutcome\s+outcome\s*=' "$CTRL"
}

check_F2_ok_with_warning() {
    file_contains 'ResponseEntity\.ok\s*\(' "$CTRL" && file_contains '"warning"' "$CTRL"
}

# NEGATIVE: full success still returns 204 — REGULAR bulk import untouched.
check_F2_success_still_204() {
    file_contains 'ResponseEntity\.status\(HttpStatus\.NO_CONTENT\)\.body\(Collections\.singletonMap\("status", "success"\)\)' "$CTRL"
}

# NEGATIVE: the warning is NOT attached to a 204 (processWmsResponse:460 would
# short-circuit and never parse the body — the warning would be invisible).
check_F2_warning_not_on_204() {
    file_not_contains_multiline 'NO_CONTENT\)[^;]{0,400}warning' "$CTRL"
}

# POSITIVE: the ADVICE_IMPORT audit row records 200 on the warning branch.
# Anchored on the ADVICE_IMPORT block's own "N/A" line so the window cannot span
# from the :424 success log into the :441 FAILED log (which is a different call).
check_F2_audit_row_records_200() {
    file_contains_multiline \
        'MessageProcessType\.ADVICE_IMPORT,\s*\n\s*"N/A",[^;]{0,400}HttpStatus\.OK\.value\(\)' "$CTRL"
}

# NEGATIVE: the audit row no longer hard-codes NO_CONTENT/null unconditionally.
# ⚠ MUST be windowed. HttpStatus.NO_CONTENT.value() appears THREE times in this
# file: :427 (ADVICE_IMPORT — in scope) and :546 / :704 (ADVICE_TRANSFER_IMPORT and
# ADVICE_HUB_AND_SPOKE_IMPORT — both OUT of scope). A file-wide negative could only
# go green by editing two unrelated endpoints, i.e. it would reward damage.
check_F2_audit_row_not_hardcoded_204() {
    file_not_contains_multiline \
        'MessageProcessType\.ADVICE_IMPORT,\s*\n\s*"N/A",\s*\n\s*WmsConstants\.MessageStatus\.RECEIVED,\s*\n\s*Integer\.toString\(HttpStatus\.NO_CONTENT\.value\(\)\), null\);' \
        "$CTRL"
}

# === F3 — reason code grounded on a state probe ==============================

check_F3_reason_enum_present() {
    file_contains 'enum\s+FailureReason' "$SVC" \
        && file_contains 'PUTAWAY_LOCATION_REJECTED' "$SVC" \
        && file_contains 'PUTAWAY_LOCATION_MISSING' "$SVC" \
        && file_contains 'PRINTER_UNREACHABLE' "$SVC" \
        && file_contains 'ZPL_TEMPLATE_MISSING' "$SVC" \
        && file_contains 'CONFIG_MISSING' "$SVC" \
        && file_contains 'UNKNOWN' "$SVC"
}

# POSITIVE: the STATE PROBE exists and defaults to UNKNOWN.
check_F3_diagnose_present() {
    file_contains 'FailureReason\s+diagnose\s*\(' "$SVC" \
        && method_body_contains 'FailureReason\s+diagnose\s*\(' 'FailureReason\.UNKNOWN' "$SVC"
}

# POSITIVE: the probe degrades to UNKNOWN if it throws — a diagnostic must never
# turn a soft-fail back into a hard failure.
check_F3_diagnose_degrades() {
    method_body_contains 'FailureReason\s+diagnose\s*\(' 'catch\s*\(\s*RuntimeException' "$SVC"
}

check_F3_correlation_id() {
    file_contains 'UUID\.randomUUID\(\)' "$SVC" && file_contains 'correlationId=\{\}' "$SVC"
}

# POSITIVE: the PARTIAL template gained BOTH slots.
check_F3_template_has_reason_and_ref() {
    file_contains_multiline \
        'case RETURN_AUTO_RECEIVE_PARTIAL:\s*\n\s*description = "[^"]*%5s[^"]*%6s' "$CONST"
}

# NEGATIVE (SECURITY, PR #123 F4) — Route 2 trap. getMessage() on the H1 throw
# renders the REAL destination location name; it must not be read anywhere in
# the auto-receive service.
check_F3_no_getmessage_anywhere() {
    file_not_contains 'get(Localized)?Message\(\)' "$SVC"
}

# NEGATIVE — Route 1 trap. The exception key is "placeholder" for every case of
# interest, so no key-switching may appear...
check_F3_no_key_switching() {
    file_not_contains 'getMessageKey\(\)|\.getKey\(\)' "$SVC"
}

# ...and no key accessor may have been added to BusinessException to enable it.
check_F3_no_accessor_added_to_businessexception() {
    file_not_contains 'public\s+String\s+get(Message)?Key\s*\(' "$BEXC"
}

# NEGATIVE (SECURITY) — no internal name may reach the outcome-building path.
check_F3_no_internal_names_in_outcome() {
    method_body_not_contains 'AutoReceiveOutcome\s+executeInternal' \
        'getName\(\)|getAddress\(\)|putAwayLocation' "$SVC"
}

# POSITIVE + arity: exactly ONE reference to the constant, and it is a
# getErrorCodeText call passing six arguments. getErrorCodeText:1329-1332
# swallows the arity error and returns the raw template, so a four-arg site
# ships a literal "%5s" to the operator with nothing failing.
check_F3_single_construction_site() {
    file_contains_exactly_n 'WmsConstants\.RETURN_AUTO_RECEIVE_PARTIAL' "$SVC" 1 \
        && file_contains_multiline \
            'getErrorCodeText\(\s*WmsConstants\.RETURN_AUTO_RECEIVE_PARTIAL\s*,([^;]*?,){5}[^;]*?\)' \
            "$SVC"
}

# === F4 — OMS surfaces the warning without blocking ==========================

check_F4_warning_branch_present() {
    file_contains "\['data'\]\['warning'\]" "$QARET" \
        && file_contains "'status'[[:space:]]*=>[[:space:]]*'warning'" "$QARET"
}

check_F4_warning_logged() { file_contains "correlation_id" "$QARET"; }

# Anchored on the actual expression, not the words: a comment mentioning
# "received_in_wms" and "warning" would satisfy a looser pattern.
check_F4_received_flag_tightened() {
    file_contains_multiline \
        "received_in_wms.{0,300}in_array\(.{0,120}'skipped'.{0,40}'warning'" "$QARET"
}

# NEGATIVE: the generic hard-fail throw survives — F4 must not have broadened
# into swallowing real 4xx errors.
check_F4_generic_throw_survives() {
    file_contains "WMS failed to receive the returned inventory: " "$QARET"
}

# NEGATIVE: isFailureResponse was NOT weakened. (Not the load-bearing check per
# plan §5.2, but it must stay strict.)
check_F4_isfailureresponse_unchanged() {
    file_contains_multiline \
        "function isFailureResponse\(array .response\): bool\s*\n\s*\{\s*\n\s*return isset\(.response\['status'\]\) && .response\['status'\] === 'failure';" \
        "$WMSAPI"
}

# NEGATIVE: processWmsResponse's 204 short-circuit is intact — it is the reason
# the warning had to move to a 200, so silently "fixing" it would invalidate F2.
check_F4_204_shortcircuit_intact() {
    file_contains_multiline "if \(.response->status\(\) === 204\)" "$WMSAPI"
}

# === Scope guards ============================================================

# NEGATIVE: ReceivingService untouched — :492 is SBDEV-2731/2732's.
check_S1_receivingservice_untouched() {
    file_contains 'unitloadBusinessService\.transferUnitLoadToLocation\(unitload, putAwayLocation, false, codeReceiving, adviceposition\.getNumber\(\), null\)' "$RECV"
}

# NEGATIVE: no new Flyway migration (plan §5.3 — head must still be V2.2.09).
check_S2_no_new_migration() {
    [ -d "$MIGDIR" ] || return 1
    local head
    head=$(ls "$MIGDIR" | grep -E '^V2\.2\.[0-9]+__' | sort -V | tail -1)
    [ -n "$head" ] || return 1
    case "$head" in V2.2.09__*) return 0 ;; *) return 1 ;; esac
}

# NEGATIVE: the default-ON kill-switch read was not "consistency-fixed".
check_S3_killswitch_still_default_on() {
    method_body_contains 'boolean\s+isAutoReceiveEnabled' '!"false"\.equalsIgnoreCase' "$SVC" \
        && method_body_not_contains 'boolean\s+isAutoReceiveEnabled' 'Boolean\.parseBoolean' "$SVC"
}

# NEGATIVE: the resume fix stayed CUT (plan §5.6). It has no DB backstop, the
# over-delivery guard is disabled on this path, and IdempotencyFilter would
# replay it — do not let it reappear without §5.6's questions answered.
check_S4_no_resume_branch() {
    file_not_contains 'evaluateResume|ResumeDecision' "$SVC" \
        && file_not_contains 'evaluateResume|ResumeDecision' "$CTRL"
}

# NEGATIVE: the duplicate guard still throws unconditionally for every duplicate.
check_S4_duplicate_guard_unconditional() {
    file_contains_multiline \
        'if \(adviceOpt\.isPresent\(\)\) \{\s*\n\s*throw new WebserviceBusinessExceptionClientSide\(WmsConstants\.ENTITY_ALREADY_EXITS' \
        "$CTRL"
}

# NEGATIVE: the DEAD OMS reconcile branch was not edited (plan §2 Bug B / D8).
# Editing unreachable code is churn; making it reachable needs the getErrorMap()
# change, which belongs to Q4.
check_S5_dead_reconcile_branch_untouched() {
    file_contains "Please contact support to reconcile the existing WMS advice" "$QARET" \
        && file_contains_multiline "ENTITY_ALREADY_EXITS.{0,900}?throw new .RuntimeException" "$QARET" \
        && file_not_contains_multiline "ENTITY_ALREADY_EXITS.{0,900}?'status'\s*=>\s*'success'" "$QARET"
}

# NEGATIVE: the idempotency layer was not touched (plan §5.4 / §5.6 blocker 3).
check_S6_idempotency_untouched() {
    file_contains_multiline "Only 2xx responses are (persisted|stored)" "$IDEMP"
}

# === N5 — tests and docs that nothing else pins ==============================

# The OMS Http::fake pin is the PRIMARY guarantee behind F2's contract change
# (plan §5.2 steps 2 and 4), so its absence must fail the gate, not pass quietly.
check_N5_oms_test_pins_warning_shape() {
    [ -f "$OMSTEST" ] || return 1
    file_contains 'Http::fake' "$OMSTEST" && file_contains "warning" "$OMSTEST"
}

# Three docs must record the new failure semantics. Asserted by CONTENT, not
# mtime — a doc touched without saying anything is not an update.
# ⚠ These must key on THIS revision's vocabulary, not on "SBDEV-2778".
# §3.5 of the workflow doc already documents the ORIGINAL SBDEV-2778 and already
# contains "SBDEV-2778", "stays OPEN" and "partial_failure" — a looser assertion
# false-greened here on the pre-fix tree. Key on the follow-up marker instead.
check_N5_workflow_doc_updated() {
    file_contains 'SBDEV-2778 follow-up' "$DOC_WORKFLOW" \
        && file_contains '200-with-warning|soft-fail|RETURN_AUTO_RECEIVE_PARTIAL' "$DOC_WORKFLOW"
}

check_N5_state_machine_doc_updated() {
    file_contains 'SBDEV-2778 follow-up' "$DOC_STATEMACHINE" \
        && file_contains '200-with-warning|soft-fail|stays OPEN on a partial' "$DOC_STATEMACHINE"
}

# The archived plan that caused the regression must point forward to this one,
# or the next reader lands on superseded guidance.
check_N5_archived_plan_has_forward_pointer() {
    file_contains 'return-auto-receive-hard-blocks-return-on-partial-failure' "$DOC_ARCHIVED"
}

# === Runner ==================================================================

echo
echo "verify-SBDEV-2778-return-auto-receive-hard-blocks-return-on-partial-failure (rev3)"
echo "  WMS_ROOT=$WMS_ROOT"
echo "  OMS_ROOT=$OMS_ROOT"
echo

echo "F1 — soft-fail instead of throw"
run F1a  "execute() returns AutoReceiveOutcome"                  check_F1_execute_returns_outcome
run F1b  "failure branch returns a PARTIAL outcome"              check_F1_partial_outcome_returned
run F1c  "NEG: RETURN_AUTO_RECEIVE_PARTIAL throw is gone"        check_F1_partial_throw_gone
run F1d  "AutoReceiveOutcome record w/ SUCCESS/PARTIAL/SKIPPED"  check_F1_outcome_record_present
echo

echo "F1-regression — PR #123 guarantees survive"
run F1ra "markFinished still @Transactional + via self"          check_F1r_markfinished_intact
run F1rb "NEG: markFinished not reachable from the catch"        check_F1r_markfinished_not_in_catch
run F1rc "NEG: execute() still not @Transactional"               check_F1r_execute_still_not_transactional
echo

echo "F2 — 200-with-warning + audit row"
run F2a  "controller captures the execute() outcome"             check_F2_outcome_captured
run F2b  "200 response carrying a warning exists"                check_F2_ok_with_warning
run F2c  "NEG: full success still returns 204"                   check_F2_success_still_204
run F2d  "NEG: warning is not attached to a 204"                 check_F2_warning_not_on_204
run F2e  "audit row records HTTP 200 on the warning branch"      check_F2_audit_row_records_200
run F2f  "NEG: audit row no longer hard-codes 204/null"          check_F2_audit_row_not_hardcoded_204
echo

echo "F3 — reason code grounded on a state probe"
run F3a  "FailureReason enum with all six values"                check_F3_reason_enum_present
run F3b  "diagnose() state probe exists, defaults to UNKNOWN"    check_F3_diagnose_present
run F3c  "diagnose() degrades to UNKNOWN if it throws"           check_F3_diagnose_degrades
run F3d  "PARTIAL template has %5s reason + %6s ref"             check_F3_template_has_reason_and_ref
run F3e  "correlation id generated and logged"                   check_F3_correlation_id
run F3f  "NEG(sec): getMessage() read nowhere (Route 2 trap)"    check_F3_no_getmessage_anywhere
run F3g  "NEG: no key switching (Route 1 trap)"                  check_F3_no_key_switching
run F3g2 "NEG: no key accessor added to BusinessException"       check_F3_no_accessor_added_to_businessexception
run F3h  "NEG(sec): no printer/location name in the outcome"     check_F3_no_internal_names_in_outcome
run F3i  "exactly one construction site, six args (arity trap)"  check_F3_single_construction_site
echo

echo "F4 — OMS surfaces the warning without blocking"
run F4a  "warning branch reads response.data.warning"            check_F4_warning_branch_present
run F4b  "warning logged with correlation_id"                    check_F4_warning_logged
run F4c  "received_in_wms excludes the warning status"           check_F4_received_flag_tightened
run F4d  "NEG: generic hard-fail throw survives"                 check_F4_generic_throw_survives
run F4e  "NEG: isFailureResponse body unchanged"                 check_F4_isfailureresponse_unchanged
run F4f  "NEG: processWmsResponse 204 short-circuit intact"      check_F4_204_shortcircuit_intact
echo

echo "Scope guards"
run S1   "NEG: ReceivingService:492 untouched (2731/2732)"       check_S1_receivingservice_untouched
run S2   "NEG: no new Flyway migration (head still V2.2.09)"     check_S2_no_new_migration
run S3   "NEG: kill switch still default-ON"                     check_S3_killswitch_still_default_on
run S4   "NEG: resume stayed CUT (plan section 5.6)"             check_S4_no_resume_branch
run S4b  "NEG: duplicate guard still unconditional"              check_S4_duplicate_guard_unconditional
run S5   "NEG: dead OMS reconcile branch untouched"              check_S5_dead_reconcile_branch_untouched
run S6   "NEG: idempotency layer untouched"                      check_S6_idempotency_untouched
echo

echo "Docs + OMS test coverage"
run N5a  "OMS test pins the Http::fake warning shape"            check_N5_oms_test_pins_warning_shape
run N5b  "receiving/putaway workflow doc records the soft-fail"  check_N5_workflow_doc_updated
run N5c  "state-machine catalog records advice stays OPEN"       check_N5_state_machine_doc_updated
run N5d  "archived SBDEV-2778 plan points forward to this one"   check_N5_archived_plan_has_forward_pointer
echo

if [ "$RUN_MVN" = "1" ]; then
    echo "Targeted JUnit"
    run T1 "ReturnAdviceAutoReceiveServiceUnitTest passes" mvn_test_passes ReturnAdviceAutoReceiveServiceUnitTest
    run T2 "AdviceRestControllerUnitTest passes"           mvn_test_passes AdviceRestControllerUnitTest
    echo
else
    skip T1 "ReturnAdviceAutoReceiveServiceUnitTest" "RUN_MVN=0"
    skip T2 "AdviceRestControllerUnitTest"           "RUN_MVN=0"
    echo
fi

echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
