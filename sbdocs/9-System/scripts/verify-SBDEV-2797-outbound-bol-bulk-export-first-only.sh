#!/usr/bin/env bash
# verify-SBDEV-2797-outbound-bol-bulk-export-first-only.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2797-outbound-bol-bulk-export-first-only.md
#
# Usage:
#   bash sbdocs/9-System/scripts/verify-SBDEV-2797-outbound-bol-bulk-export-first-only.sh
#   PROJECT_ROOT=/path/to/wms2-api UI_ROOT=/path/to/wms2-web-ui bash ...
#
# This plan spans TWO repos. UI rows SKIP (not FAIL) when UI_ROOT is absent, so the
# script is usable from an api-only worktree. Exit 0 only when FAIL == 0.
#
# ---------------------------------------------------------------------------
# NEGATIVE-TEST THIS SCRIPT BEFORE TRUSTING IT.
# "Result: N pass, 0 fail" is meaningless until the pre-fix baseline has been
# captured on untouched origin/develop and shows every fix row FAILING.
# (Real incident: SBDEV-2736 scored 57 pass / 0 fail on the very build that
# still contained the defect the ticket was written to catch.)
#
# Rows that are LEGITIMATELY INVARIANT and pass pre-fix by design — enumerate
# these when recording the baseline so it stays auditable (plan §9.2 step 1).
# The captured pre-fix baseline is EXACTLY these 8 and nothing else:
#   A-no-reset, B-legacy-sig, B-legacy-cancel-msg, B-no-tx-method,
#   B-no-tx-class, B-no-skip-empties, B-fileexport-unchanged,
#   C-open-still-commented
# B-no-skip-empties passes pre-fix because there is no loop on develop at all;
# it is a guard row protecting a8af84f, so a pre-fix pass is correct. Prove it
# with counter-test B rather than trusting it.
#
# NOTE: B-no-inbound-literal is NOT invariant. Under user decision 11 the
# "Inbound BOL" literal must be GONE, so it is a fix row that MUST fail pre-fix.
#
# CAPTURED BASELINE (untouched origin/develop, 2026-08-03, mvn absent):
#   Result: 8 pass, 63 fail, 3 skip   (exit 1)
# One vacuous row was caught by this very run and fixed: B-exportexcelfile was
# a whole-file check that passed pre-fix because the LEGACY method already calls
# exportExcelFile. It is now java_method-scoped to exportOutboundBOLs.
#
# COUNTER-TESTS RUN 2026-08-03 against mutated shadow copies (4 of the 8
# invariant rows PROVEN to have teeth; each flipped PASS -> FAIL on mutation):
#   A-no-reset             inject `response.reset()`            -> FAIL  ok
#   B-no-tx-method         inject @Transactional ABOVE the sig  -> FAIL  ok
#                          (B-no-tx-class correctly stayed PASS, so the two
#                           rows discriminate instead of both firing; this is
#                           why the look-back helper exists — java_method
#                           starts AT the signature and would miss it)
#   B-fileexport-unchanged append a line to FileExportService   -> FAIL  ok
#   C-open-still-commented uncomment the Open-tab Export button -> FAIL  ok
# B-legacy-sig / B-legacy-cancel-msg are literal-presence rows whose teeth are
# self-evident. B-no-skip-empties CANNOT be counter-tested pre-fix because
# exportOutboundBOLs does not exist yet — that is counter-test B in plan §9.2
# and it is DEFERRED to the implementation phase. Do not mark it proven.
#
# LANDMINE guarded below: the perl -0777 multi-line helpers in the shared
# template FAIL OPEN — perl exits 0 when it cannot open the file, so every
# multi-line assertion about a missing/new file false-greens. Every helper here
# therefore starts with an explicit file-existence guard.
#
# LANDMINE guarded below: negatives are scoped with java_method / js_action, NOT
# with a `.{0,N}?` character window. Windows are a function of comment length;
# SBDEV-2632 §9.1 records a false-red where a mandated comment block pushed
# resetBuffer() 793 chars past its anchor and blew a {0,700} window.
# ---------------------------------------------------------------------------

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
UI_ROOT="${UI_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-web-ui}"

[ -d "$PROJECT_ROOT" ] || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }
cd "$PROJECT_ROOT" || { echo "FATAL: cannot cd to PROJECT_ROOT=$PROJECT_ROOT"; exit 2; }

PASS=0; FAIL=0; SKIP=0

# run <id> <description> <command...>
run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-28s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-28s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

# skip <id> <description> <reason>
skip() {
    local id=$1 desc=$2 reason=$3
    printf "  SKIP  %-28s  %s  (%s)\n" "$id" "$desc" "$reason"; SKIP=$((SKIP+1))
}

# run_ui <id> <description> <command...>  — SKIP when the UI repo is unavailable.
run_ui() {
    local id=$1 desc=$2; shift 2
    if [ ! -d "$UI_ROOT" ]; then
        skip "$id" "$desc" "UI_ROOT=$UI_ROOT not found"; return
    fi
    run "$id" "$desc" "$@"
}

# run_mvn <id> <description> <command...> — SKIP when maven is not on PATH.
# (SDKMAN: export PATH="$HOME/.sdkman/candidates/maven/current/bin:$PATH")
run_mvn() {
    local id=$1 desc=$2; shift 2
    if ! command -v mvn >/dev/null 2>&1; then
        skip "$id" "$desc" "mvn not on PATH"; return
    fi
    run "$id" "$desc" "$@"
}

# --- assertion helpers (every one guards file existence FIRST) ---------------

file_contains()     { [ -f "$2" ] || return 1; grep -qE "$1" "$2"; }
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }
file_exists()       { [ -f "$1" ]; }

# Exact occurrence count on a single file.
file_count_eq() {
    [ -f "$2" ] || return 1
    local n; n=$(grep -cE "$1" "$2" 2>/dev/null || echo 0)
    [ "$n" -eq "$3" ]
}

# Multi-line (slurped) regex match.
#
# Two traps handled here, both verified empirically:
#  1. FAIL-OPEN: `perl -0777 -ne` exits 0 when it cannot open the file, so an
#     assertion about a missing/new file silently passes. The `[ -f ]` guard is
#     REQUIRED.
#  2. DELIMITER BREAK: interpolating the pattern into /.../ breaks on any '/' in
#     the pattern (e.g. "application/json"), so the check FALSE-REDS. Pass the
#     pattern through the environment instead of interpolating it.
file_contains_ml() {
    [ -f "$2" ] || return 1
    VERIFY_PAT="$1" perl -0777 -ne 'exit($_ =~ /$ENV{VERIFY_PAT}/s ? 0 : 1)' "$2"
}

# Multi-line negative. Same two guards, inverted result.
file_not_contains_ml() {
    [ -f "$2" ] || return 1
    VERIFY_PAT="$1" perl -0777 -ne 'exit($_ =~ /$ENV{VERIFY_PAT}/s ? 1 : 0)' "$2"
}

# Extract one Java method body by name (brace-agnostic: method start → next
# line that is exactly 4-space-indented "}"). Used for method-scoped negatives
# so an assertion about exportOutboundBol is not satisfied/broken by a sibling.
java_method() {
    [ -f "$1" ] || return 1
    awk "/(public|private|protected|static).*[ ]$2\\(/,/^    \\}\$/" "$1"
}

# Strip Java comments from stdin.
#
# REQUIRED for any NEGATIVE or ORDERING assertion, because a comment that merely
# DISCUSSES the forbidden construct otherwise trips the check. This produced three
# false-REDs on the first post-fix run of this very script:
#   - an explanatory comment quoting "Inbound BOL" while saying it was removed
#   - a Javadoc naming @Transactional while explaining why there is none
#   - a comment mentioning findById ABOVE the try, defeating the ordering check
# Stripping comments rather than deleting the prose keeps the rationale in the code
# (the resetBuffer/CORS comment is load-bearing knowledge) while keeping the
# assertions honest. Generalises the character-window trap recorded in 2632 §9.1.
strip_java_comments() {
    perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g'
}

# Extract one Vuex action / Vue method body from a JS/Vue file.
js_action() {
    [ -f "$1" ] || return 1
    awk "/$2\\(/,/^  \\},\$/" "$1"
}

# Annotation-aware negative: java_method starts AT the signature line, so an
# annotation sitting ABOVE it would escape a method-scoped grep. Look back 3
# lines from the signature instead.
no_annotation_above() {
    [ -f "$1" ] || return 1
    # Comments stripped FIRST: a Javadoc explaining why a method is NOT @Transactional
    # would otherwise trip this. java_method starts AT the signature line, so an
    # annotation above it needs this look-back form rather than method scoping.
    ! strip_java_comments < "$1" | grep -B3 -E "$2" | grep -qE "$3"
}

mvn_test_passes() {
    # `mvn -q` suppresses the surefire summary, so grepping output false-fails on
    # passing tests. Surefire fails the build on any test failure, so the exit
    # code is the reliable signal.
    #
    # WARNING: `mvn test` MUTATES the tracked archunit_store — revert it after.
    # And -Dtest='Outer#method' silently no-ops for @Nested tests, so always
    # target the OUTER class here.
    mvn test -Dtest="$1" -DfailIfNoTests=false -q >/dev/null 2>&1
}

jest_passes() {
    ( cd "$UI_ROOT" && node_modules/.bin/jest --testPathPattern="$1" --silent ) >/dev/null 2>&1
}

# run_jest <id> <description> <pattern> — SKIP unless the UI repo has node_modules
# and a jest binary (no `yarn` on PATH in this environment; use the nvm node).
run_jest() {
    local id=$1 desc=$2 pattern=$3
    if [ ! -d "$UI_ROOT" ]; then
        skip "$id" "$desc" "UI_ROOT not found"; return
    fi
    if [ ! -x "$UI_ROOT/node_modules/.bin/jest" ]; then
        skip "$id" "$desc" "jest not installed in UI_ROOT"; return
    fi
    run "$id" "$desc" jest_passes "$pattern"
}

# --- paths ------------------------------------------------------------------

CTL="src/main/java/net/aim_ai/wms/controller/BillOfLadingController.java"
SVC="src/main/java/net/aim_ai/wms/service/BillofladingService.java"
FES="src/main/java/net/aim_ai/wms/service/FileExportService.java"
CTL_TEST="src/test/java/net/aim_ai/wms/unit/controller/BillOfLadingControllerUnitTest.java"
SVC_TEST="src/test/java/net/aim_ai/wms/unit/service/BillofladingServiceUnitTest.java"

UI_POP="$UI_ROOT/components/outbound/bol/popups/exportBolPop.vue"
UI_CLOSED="$UI_ROOT/components/outbound/bol/closedOutboundBol.vue"
UI_OPEN="$UI_ROOT/components/outbound/bol/openOutboundBol.vue"
UI_DETAILS="$UI_ROOT/components/outbound/bol/outboundBolDetails.vue"
UI_STORE="$UI_ROOT/store/outbound/outboundBols.js"

UI_SPEC_OPEN="$UI_ROOT/test/components/outbound/bol/openOutboundBol.spec.js"
UI_SPEC_POP="$UI_ROOT/test/components/outbound/bol/exportBolPop.spec.js"
UI_SPEC_CLOSED="$UI_ROOT/test/components/outbound/bol/closedOutboundBol.spec.js"
UI_SPEC_STORE="$UI_ROOT/test/store/outbound/outboundBols.spec.js"

echo
echo "verify-SBDEV-2797 — Outbound BOL bulk export (build the missing multi-BOL path)"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  UI_ROOT=$UI_ROOT"
echo

# === Fix A — controller: accept ids, everything inside the try ===============
echo "Fix A — BillOfLadingController.exportOutboundBol"

check_A_parse_helper()  { file_contains 'public\s+static\s+List<Long>\s+parseBolIds\s*\(' "$CTL"; }
# Scoped to the helper. A whole-file check for both keys is VACUOUS: closeOutboundBols
# already reads reqMap.get("bolIds") and the pre-fix export() already reads
# reqMap.get("id"), so an unscoped check can pass pre-fix.
check_A_both_shapes()   { file_contains_ml 'parseBolIds.{0,2000}?reqMap\.get\("ids"\).{0,600}?reqMap\.get\("id"\)' "$CTL"; }
check_A_trim()          { [ -f "$CTL" ] || return 1; java_method "$CTL" parseBolIds | grep -qE '\.trim\(\)'; }
check_A_biz_bad_token() { file_contains_ml 'catch\s*\(NumberFormatException.{0,300}?throw new BusinessException' "$CTL"; }
check_A_cap_declared()  { file_contains 'MAX_BULK_EXPORT_BOLS\s*=\s*100' "$CTL"; }
check_A_cap_enforced()  { [ -f "$CTL" ] || return 1; java_method "$CTL" parseBolIds | grep -qE 'MAX_BULK_EXPORT_BOLS'; }
check_A_error_writer()  { file_contains 'private void writeExportError' "$CTL"; }
check_A_resetbuffer()   { [ -f "$CTL" ] || return 1; java_method "$CTL" writeExportError | grep -qE 'response\.resetBuffer'; }
check_A_sets_status()   { [ -f "$CTL" ] || return 1; java_method "$CTL" writeExportError | grep -qE 'response\.setStatus'; }
check_A_json_ctype()    { [ -f "$CTL" ] || return 1; java_method "$CTL" writeExportError | grep -qE 'APPLICATION_JSON_VALUE|application/json'; }
check_A_iscommitted()   { [ -f "$CTL" ] || return 1; java_method "$CTL" writeExportError | grep -qE 'isCommitted'; }
check_A_422()           { file_contains 'UNPROCESSABLE_ENTITY' "$CTL"; }
check_A_calls_bulk()    { file_contains 'exportOutboundBOLs\s*\(' "$CTL"; }
check_A_objectmapper()  { file_contains 'WmsObjectMapper' "$CTL"; }

run A-parse-helper      "parseBolIds declared public static"          check_A_parse_helper
run A-both-shapes       "parseBolIds reads both ids and id"           check_A_both_shapes
run A-trim              "parseBolIds trims string tokens"             check_A_trim
run A-biz-bad-token     "bad token -> BusinessException (422 path)"   check_A_biz_bad_token
run A-cap-declared      "MAX_BULK_EXPORT_BOLS = 100 declared"         check_A_cap_declared
run A-cap-enforced      "cap enforced inside parseBolIds"             check_A_cap_enforced
run A-error-writer      "writeExportError helper exists"              check_A_error_writer
run A-resetbuffer       "writeExportError uses resetBuffer()"         check_A_resetbuffer
run A-sets-status       "writeExportError sets a status"              check_A_sets_status
run A-json-ctype        "writeExportError sets JSON content type"     check_A_json_ctype
run A-iscommitted       "writeExportError guards on isCommitted()"    check_A_iscommitted
run A-422               "UNPROCESSABLE_ENTITY used"                   check_A_422
run A-calls-bulk        "controller calls exportOutboundBOLs"         check_A_calls_bulk
run A-objectmapper      "WmsObjectMapper used for the error body"     check_A_objectmapper

# --- Fix A negatives ---
# Method-scoped: setDestinationFacility:185 legitimately keeps the identical
# ((Integer) reqMap.get(...)) construct, so a WHOLE-FILE check can never pass.
check_A_no_int_cast()   { [ -f "$CTL" ] || return 1; ! java_method "$CTL" exportOutboundBol | grep -qE '\(\(Integer\) reqMap\.get\("id"\)\)\.longValue\(\)'; }
check_A_no_errors_str() { [ -f "$CTL" ] || return 1; ! java_method "$CTL" exportOutboundBol | grep -qE 'errors\.toString\(\)'; }
# Whole-file is correct for this one: `grep -c 'response.reset()'` on develop is 0.
check_A_no_reset()      { file_not_contains 'response\.reset\(\)' "$CTL"; }
# Ordering assertion: the try must OPEN before any parse/lookup. Pre-fix, findById
# sits at :273 and the try at :275, so this fails on develop.
check_A_lookup_in_try() {
    [ -f "$CTL" ] || return 1
    local body try_ln work_ln
    body=$(java_method "$CTL" exportOutboundBol | strip_java_comments) || return 1
    try_ln=$(printf '%s\n' "$body"  | grep -nE 'try[[:space:]]*\{'          | head -1 | cut -d: -f1)
    work_ln=$(printf '%s\n' "$body" | grep -nE 'parseBolIds|findAllById|findById' | head -1 | cut -d: -f1)
    [ -n "$try_ln" ] && [ -n "$work_ln" ] && [ "$try_ln" -lt "$work_ln" ]
}

run A-no-integer-cast   "pre-try (Integer) cast gone [method-scoped]"  check_A_no_int_cast
run A-no-errors-tostr   "errors.toString() gone [method-scoped]"       check_A_no_errors_str
run A-no-reset          "response.reset() absent [INVARIANT pre-fix]"  check_A_no_reset
run A-lookup-in-try     "parse+lookup happen INSIDE the try"           check_A_lookup_in_try

# === Fix B — service: Summary + one sheet per BOL ============================
echo
echo "Fix B — BillofladingService.exportOutboundBOLs"

check_B_bulk_sig()      { file_contains 'exportOutboundBOLs\s*\(\s*HttpServletResponse' "$SVC"; }
check_B_getexcelfile()  { file_contains 'getExcelFile\s*\(' "$SVC"; }
# MUST be scoped to the bulk method. A whole-file check is VACUOUS: the legacy
# exportOutboundBOL already calls exportExcelFile, so it passes pre-fix.
# (Caught in the pre-fix baseline run — it was the only non-invariant PASS.)
check_B_exportexcel()   { [ -f "$SVC" ] || return 1; java_method "$SVC" exportOutboundBOLs | grep -qE 'exportExcelFile\s*\('; }
check_B_uniquesheet()   { file_contains 'uniqueSheetName' "$SVC"; }
check_B_safesheet()     { file_contains 'WorkbookUtil\.createSafeSheetName' "$SVC"; }
check_B_blockreason()   { file_contains 'exportBlockReason' "$SVC"; }
check_B_buildsheet()    { file_contains 'buildSheetData' "$SVC"; }
check_B_sheetdata_rec() { file_contains 'BolSheetData' "$SVC"; }
check_B_single_deleg()  { file_contains_ml 'size\(\)\s*==\s*1' "$SVC"; }
check_B_summary_const() { file_contains 'SUMMARY_SHEET_NAME' "$SVC"; }
check_B_summary_seed()  { file_contains 'usedSheetNames\.add\(\s*SUMMARY_SHEET_NAME\s*\)' "$SVC"; }
check_B_summary_hdr()   { file_contains_ml 'SKU Rows' "$SVC"; }
# user decision 11: the legacy single-BOL path must now name its sheet the same way.
check_B_legacy_unique() { [ -f "$SVC" ] || return 1; java_method "$SVC" exportOutboundBOL | grep -qE 'uniqueSheetName|createSafeSheetName'; }
check_B_legacy_sig()    { file_contains 'exportOutboundBOL\s*\(\s*HttpServletResponse response, Billoflading' "$SVC"; }
check_B_cancel_msg()    { file_contains 'Can not export from an cancelled outbound BOL' "$SVC"; }

run B-bulk-sig          "exportOutboundBOLs(HttpServletResponse,...) declared" check_B_bulk_sig
run B-getexcelfile      "getExcelFile accumulation call present"        check_B_getexcelfile
run B-exportexcelfile   "exportExcelFile present for the final sheet"   check_B_exportexcel
run B-uniquesheetname   "uniqueSheetName dedup helper present"          check_B_uniquesheet
run B-safesheetname     "WorkbookUtil.createSafeSheetName used"         check_B_safesheet
run B-exportblockreason "exportBlockReason state gate extracted"        check_B_blockreason
run B-buildsheetdata    "buildSheetData shared builder extracted"       check_B_buildsheet
run B-bolsheetdata      "BolSheetData carrier type declared"            check_B_sheetdata_rec
run B-single-delegation "N==1 delegates to the single-BOL path"         check_B_single_deleg
run B-summary-const     "SUMMARY_SHEET_NAME declared"                   check_B_summary_const
run B-summary-seeded    "usedSheetNames seeded with SUMMARY_SHEET_NAME" check_B_summary_seed
run B-summary-header    "summary header carries the SKU Rows column"    check_B_summary_hdr
run B-legacy-uniquename "legacy path also names sheets by BOL number"   check_B_legacy_unique
run B-legacy-sig        "legacy signature intact [INVARIANT pre-fix]"   check_B_legacy_sig
run B-legacy-cancel-msg "CANCELLED message intact [INVARIANT pre-fix]"  check_B_cancel_msg

# --- Fix B negatives ---
# user decision 11 flipped this from a POSITIVE to a NEGATIVE: the literal must GO.
check_B_no_inbound()    { [ -f "$SVC" ] || return 1; ! strip_java_comments < "$SVC" | grep -qE '"Inbound BOL"'; }
# TWO separate rows, never one whole-file check: BillofladingService.java
# legitimately carries @Transactional at :218, :285, :295, :752, :1025.
# java_method starts AT the signature, so an annotation above it would escape —
# hence the look-back form.
check_B_no_tx_method()  { no_annotation_above "$SVC" 'void exportOutboundBOLs?\(' '@Transactional'; }
check_B_no_tx_class()   { no_annotation_above "$SVC" 'public class BillofladingService' '@Transactional'; }
# a8af84f deliberately made position-less BOLs export empty. Guard it.
check_B_no_skip_empty() { [ -f "$SVC" ] || return 1; ! java_method "$SVC" exportOutboundBOLs | grep -qE 'isEmpty\(\)\s*\)\s*\{?\s*continue'; }
check_B_fes_untouched() { git diff --quiet origin/develop -- "$FES" 2>/dev/null; }

run B-no-inbound-literal "\"Inbound BOL\" literal GONE (decision 11)"   check_B_no_inbound
run B-no-tx-method       "no @Transactional on either export method"     check_B_no_tx_method
run B-no-tx-class        "no @Transactional on the class declaration"    check_B_no_tx_class
run B-no-skip-empties    "no skip-empties continue (protects a8af84f)"   check_B_no_skip_empty
run B-fileexport-unchanged "FileExportService.java untouched vs develop" check_B_fes_untouched

# === Fix C — closed tab: multi-select + live bulk Export bar =================
echo
echo "Fix C — closedOutboundBol.vue"

check_C_show_select()   { file_contains 'show-select' "$UI_CLOSED"; }
check_C_vmodel()        { file_contains 'v-model="selectedItems"' "$UI_CLOSED"; }
check_C_bulk_btn()      { file_contains_ml 'Export BOLs' "$UI_CLOSED"; }
check_C_rowaction()     { file_contains 'rowActionItems' "$UI_CLOSED"; }
check_C_open_evidence() { file_contains_ml 'a8af84f' "$UI_OPEN"; }

run_ui C-show-select      "closed tab data table has show-select"      check_C_show_select
run_ui C-vmodel           "closed tab binds v-model=selectedItems"     check_C_vmodel
run_ui C-bulk-export-btn  "closed tab has a bulk Export BOLs button"   check_C_bulk_btn
run_ui C-rowactionitems   "per-row path uses its own rowActionItems"   check_C_rowaction
run_ui C-open-evidence    "open tab comment cites a8af84f evidence"    check_C_open_evidence

# --- Fix C negatives ---
# Method-scoped: the bulk Cancel button legitimately sets selectedItems = [].
check_C_no_clobber()    { [ -f "$UI_CLOSED" ] || return 1; ! js_action "$UI_CLOSED" addToSelectedItems | grep -qE 'this\.selectedItems = \[\]'; }
# The Open tab's bulk Export button must STAY commented out (decision: Closed-tab only).
check_C_open_commented(){ file_contains_ml '<!--\s*<v-btn[^>]*showExportPop[\s\S]{0,200}?-->' "$UI_OPEN"; }

run_ui C-no-clobber           "addToSelectedItems no longer clobbers selection" check_C_no_clobber
run_ui C-open-still-commented "open tab Export button still commented [INVARIANT]" check_C_open_commented

# === Fix D — popup sends every id; detail page stops accumulating ============
echo
echo "Fix D — exportBolPop.vue + outboundBolDetails.vue"

check_D_ids()           { file_contains_ml 'ids:\s*this\.selectedItems\.map' "$UI_POP"; }
check_D_empty_guard()   { file_contains_ml 'selectedItems\.length\s*===?\s*0|!this\.selectedItems\.length' "$UI_POP"; }
check_D_multi_name()    { file_contains 'BOL_Export_Multiple' "$UI_POP"; }
check_D_details_assign(){ [ -f "$UI_DETAILS" ] || return 1; ! js_action "$UI_DETAILS" exportBol | grep -qE 'this\.selectedItems\.push'; }

run_ui D-ids-array       "popup dispatches an ids array"               check_D_ids
run_ui D-empty-guard     "popup guards an empty selection"             check_D_empty_guard
run_ui D-multi-filename  "multi export uses BOL_Export_Multiple"       check_D_multi_name
run_ui D-details-assigns "detail page assigns instead of pushing"      check_D_details_assign

# --- Fix D negatives ---
check_D_no_index_zero() { file_not_contains 'selectedItems\[0\]' "$UI_POP"; }
check_D_no_console()    { file_not_contains 'console\.log' "$UI_POP"; }

run_ui D-no-index-zero  "selectedItems[0] GONE from exportBolPop"      check_D_no_index_zero
run_ui D-no-console-log "console.log GONE from exportBolPop"           check_D_no_console

# === Fix E — store: check before downloading, then clean up =================
echo
echo "Fix E — store/outbound/outboundBols.js export action"

check_E_axios_post()    { [ -f "$UI_STORE" ] || return 1; js_action "$UI_STORE" 'async export' | grep -qE '\$axios\.post'; }
check_E_ctype_gate()    { file_contains_ml "content-type" "$UI_STORE"; }
check_E_extract()       { file_contains 'extractBlobErrorMessage' "$UI_STORE"; }
check_E_revoke()        { file_contains 'revokeObjectURL' "$UI_STORE"; }
check_E_link_remove()   { file_contains_ml 'link\.remove\(\)' "$UI_STORE"; }

run_ui E-axios-post     "export action uses \$axios.post (full response)" check_E_axios_post
run_ui E-ctype-gate     "content-type gate present before download"       check_E_ctype_gate
run_ui E-extract-helper "extractBlobErrorMessage helper present"          check_E_extract
run_ui E-revoke-url     "URL.revokeObjectURL called"                     check_E_revoke
run_ui E-link-remove    "link.remove() called"                            check_E_link_remove

# --- Fix E negatives (action-scoped: other actions legitimately use $post) ---
check_E_no_dead_guard() { [ -f "$UI_STORE" ] || return 1; ! js_action "$UI_STORE" 'async export' | grep -qE 'if \(result\.errors\)'; }
check_E_no_dollar_post(){ [ -f "$UI_STORE" ] || return 1; ! js_action "$UI_STORE" 'async export' | grep -qE '\$axios\.\$post'; }

run_ui E-no-dead-guard  "dead if (result.errors) gone [action-scoped]"   check_E_no_dead_guard
run_ui E-no-dollar-post "\$axios.\$post gone from export [action-scoped]" check_E_no_dollar_post

# === Fix F — open tab item-key phantom field ================================
echo
echo "Fix F — openOutboundBol.vue item-key"

check_F_item_key_id()   { file_contains 'item-key="id"' "$UI_OPEN"; }
check_F_no_key()        { file_not_contains 'item-key="key"' "$UI_OPEN"; }
# user decision 13: Fix F stays in the feature PR ONLY because it is tested.
check_F_spec_exists()   { file_exists "$UI_SPEC_OPEN"; }
check_F_spec_reads()    { file_contains_ml "attributes\('item-key'\)|attributes\(\"item-key\"\)" "$UI_SPEC_OPEN"; }

run_ui F-item-key-id    "openOutboundBol binds item-key=\"id\""         check_F_item_key_id
run_ui F-no-item-key-key "item-key=\"key\" GONE"                        check_F_no_key
run_ui F-spec-exists    "openOutboundBol.spec.js exists (decision 13)"  check_F_spec_exists
run_ui F-spec-reads-render "spec reads item-key from the render (H10)"  check_F_spec_reads

# === Tests ==================================================================
echo
echo "Tests"

check_T_ctl_nested()    { file_contains 'ExportOutboundBolBulk|ExportOutboundBols' "$CTL_TEST"; }
check_T_svc_nested()    { file_contains 'ExportOutboundBOLs' "$SVC_TEST"; }
# The 3 legacy sheet-name assertions must now expect the BOL number, not "Inbound BOL".
check_T_legacy_edited() { file_not_contains '"Inbound BOL"' "$SVC_TEST"; }
check_T_pop_spec()      { file_exists "$UI_SPEC_POP"; }
check_T_closed_spec()   { file_exists "$UI_SPEC_CLOSED"; }
check_T_store_spec()    { file_exists "$UI_SPEC_STORE"; }
# #19a is the ONLY Fix E scenario that fails against Bug 4's ordering defect.
check_T_store_19a()     { file_contains_ml 'application/json' "$UI_SPEC_STORE"; }

run    T-ctl-nested      "controller test has the bulk-export @Nested"  check_T_ctl_nested
run    T-svc-nested      "service test has the exportOutboundBOLs @Nested" check_T_svc_nested
run    T-legacy-edited   "3 legacy sheet-name assertions updated"       check_T_legacy_edited
run_ui T-pop-spec        "exportBolPop.spec.js exists"                  check_T_pop_spec
run_ui T-closed-spec     "closedOutboundBol.spec.js exists"             check_T_closed_spec
run_ui T-store-spec      "outboundBols store spec exists"               check_T_store_spec
run_ui T-store-19a       "store spec covers the 200+JSON-body shape"    check_T_store_19a

# Targeted suites. NOTE: -Dtest must name the OUTER class — 'Outer#method'
# silently no-ops for @Nested tests. `mvn test` MUTATES archunit_store; revert it.
run_mvn  T-mvn-service   "BillofladingServiceUnitTest passes"           mvn_test_passes BillofladingServiceUnitTest
run_mvn  T-mvn-controller "BillOfLadingControllerUnitTest passes"       mvn_test_passes BillOfLadingControllerUnitTest
run_mvn  T-mvn-compile   "mvn clean compile succeeds"                   mvn -q clean compile
run_jest T-jest-bol      "outbound BOL jest specs pass"                 "outbound/bol"
run_jest T-jest-store    "outbound BOL store spec passes"               "store/outbound/outboundBols"

# === Result =================================================================
echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
