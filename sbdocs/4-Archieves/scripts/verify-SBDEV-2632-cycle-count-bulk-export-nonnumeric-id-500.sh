#!/usr/bin/env bash
# verify-SBDEV-2632-cycle-count-bulk-export-nonnumeric-id-500.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2632-cycle-count-bulk-export-nonnumeric-id-500.md
#
# Usage:
#   bash sbdocs/9-System/scripts/verify-SBDEV-2632-cycle-count-bulk-export-nonnumeric-id-500.sh
#   PROJECT_ROOT=/path/to/wms2-api UI_ROOT=/path/to/wms2-web-ui bash ...
#
# This plan spans TWO repos. UI rows SKIP (not FAIL) when UI_ROOT is absent, so the
# script is usable from an api-only worktree. Exit 0 only when FAIL == 0.
#
# ---------------------------------------------------------------------------
# NEGATIVE-TEST THIS SCRIPT BEFORE TRUSTING IT.
# "Result: N pass, 0 fail" is meaningless until the pre-fix baseline has been
# captured on untouched origin/develop and shows every A-*/B-*/C-*/D* fix row
# FAILING. A row that passes pre-fix is vacuous and must be rewritten.
# (Real incident: SBDEV-2736 scored 57 pass / 0 fail on the very build that
# still contained the defect the ticket was written to catch.)
#
# LANDMINE guarded below: the perl -0777 multi-line helpers in the shared
# template FAIL OPEN — perl exits 0 when it cannot open the file, so every
# multi-line assertion about a missing/new file false-greens. Every helper here
# therefore starts with an explicit file-existence guard.
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
        printf "  PASS  %-18s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-18s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

# skip <id> <description> <reason>
skip() {
    local id=$1 desc=$2 reason=$3
    printf "  SKIP  %-18s  %s  (%s)\n" "$id" "$desc" "$reason"; SKIP=$((SKIP+1))
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

# Exact occurrence count on a single file.
file_count_eq() {
    [ -f "$2" ] || return 1
    local n; n=$(grep -cE "$1" "$2" 2>/dev/null || echo 0)
    [ "$n" -eq "$3" ]
}

# Multi-line (slurped) regex match.
#
# Two traps handled here, both verified empirically 2026-08-02:
#  1. FAIL-OPEN: `perl -0777 -ne` exits 0 when it cannot open the file, so an
#     assertion about a missing/new file silently passes. The `[ -f ]` guard is
#     REQUIRED. (Proven: unguarded returns 0 on /nonexistent/file.java.)
#  2. DELIMITER BREAK: interpolating the pattern into /.../ breaks on any '/' in
#     the pattern (e.g. "application/json", "/cycleCount/export") — perl sees a
#     terminated match and a syntax error, so the check FALSE-REDS. Pass the
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
# so an assertion about export() is not satisfied/broken by cancel().
java_method() {
    [ -f "$1" ] || return 1
    awk "/(public|private|protected|static).*[ ]$2\\(/,/^    \\}\$/" "$1"
}

mvn_test_passes() {
    # `mvn -q` suppresses the surefire summary, so grepping output false-fails on
    # passing tests. Surefire fails the build on any test failure, so the exit
    # code is the reliable signal.
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

CTL="src/main/java/net/aim_ai/wms/controller/CycleCountController.java"
SVC="src/main/java/net/aim_ai/wms/service/CyclecountService.java"
PROPS="src/main/resources/application.properties"
SEC="src/main/java/net/aim_ai/wms/SecurityConfiguration.java"
CTL_TEST="src/test/java/net/aim_ai/wms/unit/controller/CycleCountControllerUnitTest.java"
SVC_TEST="src/test/java/net/aim_ai/wms/unit/service/CyclecountServiceUnitTest.java"

UI_POP="$UI_ROOT/components/internalOps/cycleCount/exportCyclePop.vue"
UI_STORE="$UI_ROOT/store/internalOps/cycleCount.js"

# === Fix A — controller: tolerant parse, all inside the try =================

check_A_parse_helper()   { file_contains 'List<Long>\s+parseCycleCountIds\s*\(' "$CTL"; }
check_A_trim()           { file_contains_ml 'parseCycleCountIds.{0,1600}?\.trim\(\)' "$CTL"; }
# NOTE: must be scoped to the parse helper. A whole-file check for both keys is
# VACUOUS — /cancel already reads reqMap.get("ids") at L82 and export() already
# reads reqMap.get("id"), so it passes pre-fix. Verified against the baseline.
check_A_both_shapes()    { file_contains_ml 'parseCycleCountIds.{0,1200}?reqMap\.get\("ids"\).{0,400}?reqMap\.get\("id"\)' "$CTL"; }
check_A_biz_on_bad_id()  { file_contains_ml 'catch\s*\(NumberFormatException.{0,200}?throw new BusinessException' "$CTL"; }
check_A_error_writer()   { file_contains 'private void writeExportError' "$CTL"; }
# Scoped with java_method, NOT a character window.
#
# WHY: a `.{0,N}?` window from the declaration is measured in CHARACTERS, and the
# plan mandates a 6-line explanatory comment inside writeExportError before
# resetBuffer(). Measured against the plan's own After-code at real 4-space
# indentation, response.resetBuffer() sits 793 chars from the anchor and
# response.setStatus 825 — so windows of 700/600 FALSE-RED on correct code. (The
# first validation pass missed this because the synthetic fixture omitted the
# comment block.) java_method extracts the whole method body, so the assertion is
# independent of comment length and formatting.
check_A_sets_status()    { [ -f "$CTL" ] || return 1; java_method "$CTL" writeExportError | grep -qE 'response\.setStatus'; }
check_A_json_ctype()     { [ -f "$CTL" ] || return 1; java_method "$CTL" writeExportError | grep -qE 'APPLICATION_JSON_VALUE|application/json'; }
check_A_422()            { file_contains 'UNPROCESSABLE_ENTITY' "$CTL"; }
check_A_committed_guard(){ file_contains 'isCommitted\(\)' "$CTL"; }
# BLOCKING (plan §5 Fix A / §10): reset() clears response HEADERS, stripping the
# Access-Control-* headers Spring Security's CorsFilter already wrote -> the browser
# blocks every new 422/404/500 and the operator sees the generic toast again.
# resetBuffer() clears only the body. POSITIVE + NEGATIVE pair.
# java_method-scoped for the same reason as A-status/A-json above.
check_A_resetbuffer()    { [ -f "$CTL" ] || return 1; java_method "$CTL" writeExportError | grep -qE 'response\.resetBuffer\(\)'; }
check_A_no_reset()       { [ -f "$CTL" ] || return 1; ! java_method "$CTL" writeExportError | grep -qE 'response\.reset\(\)'; }
# 5xx must not echo e.getMessage() to the browser (JDBC URLs / tenant DB names).
# Assert the FIXED client string, not merely that a `status >= 500` test exists —
# code that branches on 500 and still writes `message` would satisfy the latter.
check_A_no_5xx_echo()    { [ -f "$CTL" ] || return 1; java_method "$CTL" writeExportError | grep -qE 'Export failed unexpectedly'; }
# Header constant lives on the SERVICE (dependency direction), not the controller.
# Require the DECLARATION: a bare grep is satisfied by a static import from the
# controller, which would also slip past check_A_no_svc_to_ctl.
check_A_header_const()   { file_contains 'static final String\s+EXPORT_SKIPPED_HEADER' "$SVC"; }
check_A_no_svc_to_ctl()  { file_not_contains 'CycleCountController\.EXPORT_SKIPPED_HEADER' "$SVC"; }
check_A_calls_plural()   { file_contains 'cyclecountService\.exportCycleCounts\(' "$CTL"; }

# NEGATIVE: the bare pre-try parse is gone (this is THE defect line).
check_A_no_bare_parse()  { file_not_contains 'Long\.parseLong\(\(String\)\s*reqMap\.get\("id"\)\)' "$CTL"; }

# NEGATIVE (method-scoped): export() no longer writes the un-parseable
# errors.toString() body. /cancel legitimately keeps its own error handling, so a
# whole-file negative would be wrong here.
check_A_export_no_raw_tostring() {
    [ -f "$CTL" ] || return 1
    ! java_method "$CTL" export | grep -qE 'getWriter\(\)\.write\(errors\.toString\(\)\)'
}

# NEGATIVE: nothing in export() runs before the try any more — the entity lookup
# moved inside. Asserts no orElseThrow appears between the method signature and
# the first `try {`.
check_A_lookup_inside_try() {
    [ -f "$CTL" ] || return 1
    ! file_contains_ml 'void\s+export\s*\([^)]*\)\s*\{(?:(?!try\s*\{).)*?orElseThrow' "$CTL"
}

# === Fix B — service: merged export, skip positionless =====================

check_B_plural_method()  { file_contains 'void\s+exportCycleCounts\s*\(' "$SVC"; }
check_B_takes_list()     { file_contains_ml 'exportCycleCounts\s*\(\s*HttpServletResponse\s+\w+\s*,\s*List<Cyclecount>' "$SVC"; }
check_B_cc_column()      { file_contains '"Cycle Count"' "$SVC"; }
check_B_sets_header()    { file_contains_ml 'setHeader\s*\(\s*[A-Za-z.]*EXPORT_SKIPPED_HEADER' "$SVC"; }
check_B_skip_list()      { file_contains_ml 'positions\.isEmpty\(\).{0,300}?(skipped|Skipped)' "$SVC"; }
# NOTE: must require the SKIPPED-LIST message. A generic "without positions"
# check is VACUOUS — legacy exportCycleCount already throws
# BusinessException("Can not export from cycle count without positions!") (note
# the trailing '!'), so it passes pre-fix. The new message ends in ': ' and
# appends the joined skipped numbers. Verified against the baseline.
check_B_all_empty_throws(){ file_contains_ml 'throw new BusinessException\([^;]{0,200}?without positions:\s*"\s*\+\s*String\.join' "$SVC"; }
check_B_client_memo()    { file_contains 'computeIfAbsent' "$SVC"; }
check_B_single_delegates(){ file_contains_ml 'size\(\)\s*==\s*1.{0,300}?exportCycleCount\s*\(' "$SVC"; }

# POSITIVE (legacy intact): the single-CC method and its legacy 6-column
# aggregated header must both still exist verbatim — this is what guarantees the
# single-selection file stays byte-identical (plan §12 decision 4).
check_B_legacy_signature(){ file_contains 'void\s+exportCycleCount\s*\(\s*HttpServletResponse\s+\w+\s*,\s*Cyclecount' "$SVC"; }
# java_method-scoped to the LEGACY method: the merged path's header array contains
# the legacy column names as a substring, so a whole-file grep would still pass even
# if the legacy method were deleted. `[ ]exportCycleCount\(` requires the paren, so
# this does not also match exportCycleCounts(.
check_B_legacy_header()  { [ -f "$SVC" ] || return 1; java_method "$SVC" exportCycleCount | grep -qE '"Client ID",\s*"Client Name",\s*"SKU ID",\s*"SKU Name",\s*"Amount before",\s*"Amount after"'; }
check_B_legacy_detail()  { [ -f "$SVC" ] || return 1; java_method "$SVC" exportCycleCount | grep -qE '"Position",\s*"Date",\s*"Client ID"'; }
# NEGATIVE: the legacy method must NOT gain the new leading column.
check_B_legacy_no_cc_col(){ [ -f "$SVC" ] || return 1; ! java_method "$SVC" exportCycleCount | grep -qE '"Cycle Count"'; }
# POSITIVE: dead-but-tested exportCycleCount2 not deleted (plan §0 row 12).
check_B_cc2_intact()     { file_contains 'void\s+exportCycleCount2\s*\(' "$SVC"; }
# NEGATIVE: no @Transactional smuggled onto the streaming export path (§11 row 4).
# Covers BOTH a method-level annotation on any exportCycleCount* method AND a
# class-level annotation on CyclecountService (the likelier violation).
check_B_no_transactional(){
    [ -f "$SVC" ] || return 1
    ! file_contains_ml 'Transactional[^\n]*\n\s*public void exportCycleCount' "$SVC" \
      && ! file_contains_ml '@Transactional[^\n]*\n\s*(@\w+[^\n]*\n\s*)*public class CyclecountService' "$SVC"
}

# === Fix C — CORS exposed header ===========================================

check_C_cors_prop()      { file_contains '^[[:space:]]*rest\.security\.cors\.exposed-headers[[:space:]]*=' "$PROPS"; }
check_C_cors_names_hdr() { file_contains '^[[:space:]]*rest\.security\.cors\.exposed-headers.*X-Export-Skipped-Cycle-Counts' "$PROPS"; }
# The code-level guarantee: additive and immune to a REST_SECURITY_CORS_EXPOSED_HEADERS
# env override, which is what turns this from an unverifiable deployment prerequisite
# into something this script can gate.
check_C_add_exposed()    { file_contains 'addExposedHeader\s*\([^)]*EXPORT_SKIPPED_HEADER' "$SEC"; }

# === Fix D — web UI ========================================================

check_D1_sends_ids()     { file_contains_ml "dispatch\(\s*'internalOps/cycleCount/exportCycleCount'.{0,200}?ids" "$UI_POP"; }
# NEGATIVE: the scalar joined-string payload is gone.
check_D1_no_scalar_id()  { file_not_contains_ml '\{\s*id:\s*this\.getExportList\(' "$UI_POP"; }

check_D2_uses_post()     { file_contains_ml "exportCycleCount\s*\(.{0,400}?\\\$axios\.post\(\s*'/cycleCount/export'" "$UI_STORE"; }
check_D2_reads_header()  { file_contains 'x-export-skipped-cycle-counts' "$UI_STORE"; }
check_D2_blob_text()     { file_contains_ml '\.text\(\).{0,400}?JSON\.parse|JSON\.parse.{0,400}?\.text\(\)' "$UI_STORE"; }
check_D2_keeps_fallback(){ file_contains 'network or server issue' "$UI_STORE"; }
# NEGATIVE (action-scoped): the dead `if (result.errors)` guard on a Blob is gone
# from the export action. Other actions in this file legitimately keep it because
# they do NOT use responseType blob.
check_D2_no_dead_guard() {
    [ -f "$UI_STORE" ] || return 1
    ! awk '/async exportCycleCount\(/,/^    \},/' "$UI_STORE" | grep -qE 'if \(result\.errors\)'
}
# NEGATIVE: the export action no longer uses the data-only $post shorthand
# (which cannot reach response.headers).
check_D2_no_dollar_post() {
    [ -f "$UI_STORE" ] || return 1
    ! awk '/async exportCycleCount\(/,/^    \},/' "$UI_STORE" | grep -qE '\$axios\.\$post'
}

# === Test-surface presence =================================================

check_T_ctl_has_export() { file_contains 'export' "$CTL_TEST" && \
                           file_contains_ml '(void|@Test)[^\n]*\n?[^\n]*export.{0,4000}?(422|UNPROCESSABLE|NumberFormat|parseCycleCountIds)' "$CTL_TEST"; }
# Merged-workbook coverage must exist SOMEWHERE. The TDD gate deliberately put it in
# CycleCountControllerUnitTest$BulkExportWorkbookContent (a real CyclecountService over
# mocked repos, asserted via ArgumentCaptor) rather than CyclecountServiceUnitTest,
# because only the controller entry point is expressible with the signatures that exist
# BEFORE implementation — so the gate compiles and fails on assertions instead of on
# javac. Accept either location; an executor adding direct service tests also satisfies it.
check_T_svc_has_plural() { file_contains 'exportCycleCounts' "$SVC_TEST" || \
                           file_contains '"Cycle Count"' "$CTL_TEST"; }
# Test #17 — the ONLY guard against the reset()/resetBuffer() CORS trap. MockMvc has
# no CorsFilter, so nothing else in the suite can catch it.
check_T_ctl_cors_test()  { file_contains 'Access-Control-Allow-Origin' "$CTL_TEST"; }
check_T_ui_spec()        { [ -f "$UI_ROOT/test/store/internalOps/cycleCount.spec.js" ]; }
# Scenario #16 needs its own component spec, else it has no test at all.
check_T_ui_pop_spec()    { [ -f "$UI_ROOT/test/components/internalOps/cycleCount/exportCyclePop.spec.js" ]; }
# jsdom 16.7 has no URL.createObjectURL: without this stub, #15 passes for the WRONG
# reason (generic toast fires on every call) — a false green. Plan §8 obligation H3.
check_T_ui_url_stub()    { [ -f "$UI_ROOT/test/store/internalOps/cycleCount.spec.js" ] && \
                           grep -qE 'createObjectURL' "$UI_ROOT/test/store/internalOps/cycleCount.spec.js"; }
# §12 mandates refreshing the cycle-count workflow doc; gate it rather than trusting prose.
check_docs_updated()     { file_not_contains 'POST /v3/cycleCount/export \{id\}' \
                           "/home/nampark/dev/wms-claude/sbdocs/3-Resources/workflows/wms2-cycle-count-workflow.md"; }

# === Runner ================================================================

echo
echo "verify-SBDEV-2632-cycle-count-bulk-export-nonnumeric-id-500 — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  UI_ROOT=$UI_ROOT"
echo

echo "-- Fix A: controller tolerant parse, everything inside the try --"
run A-parse           "parseCycleCountIds helper exists"              check_A_parse_helper
run A-trim            "parse trims each token (join(', ') safe)"      check_A_trim
run A-both            "accepts both 'ids' and 'id' payload shapes"    check_A_both_shapes
run A-bizex           "bad token -> BusinessException, not NFE"       check_A_biz_on_bad_id
run A-writer          "writeExportError helper exists"                check_A_error_writer
run A-status          "writeExportError sets an HTTP status"          check_A_sets_status
run A-json            "writeExportError writes JSON content type"     check_A_json_ctype
run A-422             "422 used for BusinessException"                check_A_422
run A-commit-guard    "isCommitted() guard before writing error"      check_A_committed_guard
run A-resetbuffer     "uses resetBuffer() (keeps CORS headers)"       check_A_resetbuffer
run A-no-reset        "NEG: reset() NOT used (would strip CORS)"      check_A_no_reset
run A-no-5xx-echo     "5xx does not echo e.getMessage() to client"    check_A_no_5xx_echo
run A-header-const    "EXPORT_SKIPPED_HEADER declared on service"     check_A_header_const
run A-no-svc-to-ctl   "NEG: no service -> controller const reference" check_A_no_svc_to_ctl
run A-plural-call     "controller calls exportCycleCounts(...)"       check_A_calls_plural
run A-no-bare-parse   "NEG: bare pre-try Long.parseLong(id) is gone"  check_A_no_bare_parse
run A-no-raw-tostring "NEG: export() no longer writes errors.toString()" check_A_export_no_raw_tostring
run A-lookup-in-try   "NEG: no orElseThrow before the try in export()" check_A_lookup_inside_try
echo

echo "-- Fix B: service merges N cycle counts, skips positionless --"
run B-plural          "exportCycleCounts declared"                    check_B_plural_method
run B-list-arg        "exportCycleCounts takes List<Cyclecount>"      check_B_takes_list
run B-cc-column       "'Cycle Count' leading column added"            check_B_cc_column
run B-skip-header     "skipped CCs reported via response header"      check_B_sets_header
run B-skip-logic      "positionless CCs collected as skipped"         check_B_skip_list
run B-all-empty       "all-positionless -> BusinessException"         check_B_all_empty_throws
run B-memo            "client lookups memoized (computeIfAbsent)"     check_B_client_memo
run B-single-deleg    "size()==1 delegates to legacy single export"   check_B_single_delegates
run B-legacy-sig      "legacy exportCycleCount signature intact"      check_B_legacy_signature
run B-legacy-hdr      "legacy 6-col aggregated header intact"         check_B_legacy_header
run B-legacy-detail   "legacy detailed header intact"                 check_B_legacy_detail
run B-legacy-no-col   "NEG: legacy method has no 'Cycle Count' col"   check_B_legacy_no_cc_col
run B-cc2-intact      "exportCycleCount2 not deleted"                 check_B_cc2_intact
run B-no-tx           "NEG: no @Transactional on the export path"     check_B_no_transactional
echo

echo "-- Fix C: CORS exposed header (required for the skipped toast) --"
run C-cors-prop       "rest.security.cors.exposed-headers present"    check_C_cors_prop
run C-cors-name       "exposed-headers names X-Export-Skipped-Cycle-Counts" check_C_cors_names_hdr
run C-add-exposed     "addExposedHeader in SecurityConfiguration"     check_C_add_exposed
echo

echo "-- Fix D: web UI sends ids, reads header, parses error blob --"
run_ui D1-ids         "export pop dispatches an ids array"            check_D1_sends_ids
run_ui D1-no-scalar   "NEG: scalar {id: getExportList(...)} gone"     check_D1_no_scalar_id
run_ui D2-post        "store uses \$axios.post (headers reachable)"   check_D2_uses_post
run_ui D2-header      "store reads x-export-skipped-cycle-counts"     check_D2_reads_header
run_ui D2-blob-err    "store parses the JSON error blob"              check_D2_blob_text
run_ui D2-fallback    "generic network toast retained as fallback"    check_D2_keeps_fallback
run_ui D2-no-dead     "NEG: dead if(result.errors) guard gone"        check_D2_no_dead_guard
run_ui D2-no-dollar   "NEG: \$post shorthand gone from export action" check_D2_no_dollar_post
echo

echo "-- Test surface --"
run    T-ctl-cases    "controller test covers export + 422/NFE path"  check_T_ctl_has_export
run    T-svc-cases    "service test covers exportCycleCounts"         check_T_svc_has_plural
run    T-cors-case    "test #17 asserts CORS headers survive error"   check_T_ctl_cors_test
run_ui T-ui-spec      "web-ui cycleCount store spec exists"           check_T_ui_spec
run_ui T-ui-pop-spec  "exportCyclePop component spec exists (#16)"    check_T_ui_pop_spec
run_ui T-ui-url-stub  "store spec stubs URL.createObjectURL (H3)"     check_T_ui_url_stub
run    T-docs         "cycle-count workflow doc updated for ids"      check_docs_updated
echo

echo "-- Targeted suites --"
run_mvn T-ctl         "CycleCountControllerUnitTest passes"  mvn_test_passes CycleCountControllerUnitTest
run_mvn T-svc         "CyclecountServiceUnitTest passes"     mvn_test_passes CyclecountServiceUnitTest
run_jest T-ui         "web-ui cycleCount jest spec passes"   cycleCount

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
