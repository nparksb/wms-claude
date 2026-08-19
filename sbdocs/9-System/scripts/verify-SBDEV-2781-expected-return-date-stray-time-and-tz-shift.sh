#!/usr/bin/env bash
# verify-SBDEV-2781-expected-return-date-stray-time-and-tz-shift.sh
#
# Machine-checkable acceptance for:
#   SBDEV-2781 — Expected Return Date shows a bogus time (and previously the wrong day)
#   Plan: sbdocs/1-Projects/wms2/plan/SBDEV-2781-expected-return-date-stray-time-and-tz-shift.md
#
# Usage
# -----
#   PROJECT_ROOT=/path/to/shadow-root \
#     bash sbdocs/9-System/scripts/verify-SBDEV-2781-expected-return-date-stray-time-and-tz-shift.sh
#
# PROJECT_ROOT must be a directory containing BOTH repos as `v2/wms2-web-ui` and
# `v2/wms2-api` (the monorepo root works; for worktree runs, build a symlink shadow
# root per the recipe in the wms-plan-executor skill so the script grades the WORK,
# not the main checkouts).
#
# Exit code is 0 only when every check passes. Paste the final "Result:" line in
# the end-of-task report.
#
# IMPORTANT — negative-test this script before trusting it.
# A grep script can report "0 fail" against a build that still contains the defect.
# Replay each pre-fix file (e.g. `git show HEAD~1:<path> > <path>`) and confirm the
# matching check flips to FAIL. See the plan §7.5.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

# --- toolchain ---------------------------------------------------------------
# mvn / java are NOT on PATH in this environment — they live under SDKMAN. Without
# this, T3/T4 FAIL for a tooling reason and read as code defects, which is worse
# than not running them at all. Resolve them here; if still absent, the behavioural
# rows SKIP with an explicit reason instead of reporting a phantom failure.
for _sdk in "$HOME/.sdkman/candidates/java/current/bin" "$HOME/.sdkman/candidates/maven/current/bin"; do
    [ -d "$_sdk" ] && PATH="$_sdk:$PATH"
done
export PATH
export JAVA_HOME="${JAVA_HOME:-$HOME/.sdkman/candidates/java/current}"

have_mvn()  { command -v mvn  >/dev/null 2>&1; }
have_jest() { [ -x "$PROJECT_ROOT/v2/wms2-web-ui/node_modules/.bin/jest" ]; }

UI="v2/wms2-web-ui"
API="v2/wms2-api"

OPEN_NOTICES="$UI/components/receiving/open/openNotices.vue"
CLOSED_NOTICES="$UI/components/receiving/closed/closedNotices.vue"
RECEIPT_TABLE="$UI/components/receiving/open/openNoticeReceiptTable.vue"
BOL_DETAILS="$UI/components/outbound/bol/outboundBolDetails.vue"
OPEN_DESC="$UI/components/receiving/open/openNoticeDescription.vue"
ADVICE_REPO="$API/src/main/java/net/aim_ai/wms/repo/jpa/AdviceRepository.java"
VIEW_DTO="$API/src/main/java/net/aim_ai/wms/service/ViewDtoService.java"
FILE_EXPORT="$API/src/main/java/net/aim_ai/wms/service/FileExportService.java"

PASS=0
FAIL=0
SKIP=0

# run <id> <description> <command...>
run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"
        PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"
        FAIL=$((FAIL+1))
    fi
}

skip() {
    local id=$1 desc=$2 reason=$3
    printf "  SKIP  %-10s  %s  (%s)\n" "$id" "$desc" "$reason"
    SKIP=$((SKIP+1))
}

# --- assertion helpers -------------------------------------------------------
# Both helpers assert the file EXISTS first. Without the guard, `file_not_contains`
# fails OPEN on a missing/renamed file (grep exits 2, `!` turns that into success),
# which false-greens every negative check.

file_contains() {
    [ -f "$2" ] || return 1
    grep -qE "$1" "$2"
}

file_not_contains() {
    [ -f "$2" ] || return 1
    ! grep -qE "$1" "$2"
}

# Match a regex on at least N lines.
file_contains_n_times() {
    local pattern=$1 file=$2 n=$3 count
    [ -f "$file" ] || return 1
    count=$(grep -cE "$pattern" "$file" 2>/dev/null || echo 0)
    [ "$count" -ge "$n" ]
}

# A maven test class exists and currently passes (run from the API repo).
#
# NB: gate on the EXIT CODE, not on grepping stdout. The verify-plan-template's
# helper greps for "BUILD SUCCESS|Tests run.*Failures: 0", but `-q` suppresses both
# lines, so that helper reports FAIL for a suite that passed cleanly (measured:
# ViewDtoServiceUnitTest exits 0 while printing neither string). Also require the
# class to exist first — `-DfailIfNoTests=false` makes a typo'd class name exit 0,
# which would false-GREEN a test that was never written.
mvn_test_passes() {
    local test_class=$1
    [ -n "$(find "$PROJECT_ROOT/$API/src/test" -name "${test_class}.java" -print -quit 2>/dev/null)" ] || return 1
    ( cd "$PROJECT_ROOT/$API" && mvn test -Dtest="$test_class" -DfailIfNoTests=false -q >/dev/null 2>&1 )
}

# A jest spec file exists and currently passes.
# Same reasoning: require a matching spec file, then gate on the exit code —
# `jest --testPathPattern` with no match exits 0 and would false-GREEN.
jest_spec_passes() {
    local pattern=$1
    [ -n "$(find "$PROJECT_ROOT/$UI/test" -name "*${pattern}*.spec.js" -print -quit 2>/dev/null)" ] || return 1
    ( cd "$PROJECT_ROOT/$UI" && node_modules/.bin/jest --testPathPattern="$pattern" --coverage=false >/dev/null 2>&1 )
}

# === GUARD: Fix A is ALREADY on origin/develop (e6ca85a, 2026-07-31). These rows pin it
# === against a revert; they PASS at baseline and are NOT deliverables of this plan. =========

check_A1_open_keeps_date() {
    file_contains 'getDate\(item\.dayofdelivery\)' "$OPEN_NOTICES"
}

check_A1_open_time_gone() {
    file_not_contains 'getTime\(item\.dayofdelivery\)' "$OPEN_NOTICES"
}

# The header column must survive — a "fix" that deletes the column entirely is wrong.
check_A1_open_column_intact() {
    file_contains "value: 'dayofdelivery'" "$OPEN_NOTICES"
}

# === Fix A — Closed Inbound Notices "Expected" cell is date-only ==============

check_A2_closed_keeps_date() {
    file_contains 'getDate\(item\.dayofdelivery\)' "$CLOSED_NOTICES"
}

check_A2_closed_time_gone() {
    file_not_contains 'getTime\(item\.dayofdelivery\)' "$CLOSED_NOTICES"
}

check_A2_closed_column_intact() {
    file_contains "value: 'dayofdelivery'" "$CLOSED_NOTICES"
}

# ANTI-OVER-FIX: `modified` IS a timestamptz, so the "Closed" column must KEEP its
# time. This is the single most likely way to break something while fixing this bug.
check_A2_closed_modified_keeps_time() {
    file_contains 'getTime\(item\.modified\)' "$CLOSED_NOTICES"
}

# The getTime() method definition must remain in closedNotices.vue (used by `modified`).
check_A2_closed_gettime_method_kept() {
    file_contains 'getTime\s*\(' "$CLOSED_NOTICES"
}

# === Fix B — dead dayofdelivery slot removed from the goods-receipt table =====

check_B_dead_slot_gone() {
    file_not_contains 'item\.dayofdelivery' "$RECEIPT_TABLE"
}

# The table itself must still be there and still render its real columns.
check_B_table_intact() {
    file_contains "value: 'unitloadId'" "$RECEIPT_TABLE"
}

# === Fix C — the three HAL search resources are unexported ====================

check_C1_detailview_unexported() {
    file_contains '@RestResource\(path = "getDetailViewByKeyword".*exported = false' "$ADVICE_REPO"
}

check_C2_open_unexported() {
    file_contains '@RestResource\(path = "getOpenNoticesByKeyword".*exported = false' "$ADVICE_REPO"
}

check_C3_closed_unexported() {
    file_contains '@RestResource\(path = "getClosedNoticesByKeyword".*exported = false' "$ADVICE_REPO"
}

# NEGATIVE: no *NoticesByKeyword / DetailViewByKeyword @RestResource may remain
# without `exported = false`. Catches a partial edit (two of three done).
check_C4_no_bare_export_left() {
    [ -f "$ADVICE_REPO" ] || return 1
    ! grep -E '@RestResource\(path = "(getDetailViewByKeyword|getOpenNoticesByKeyword|getClosedNoticesByKeyword)"' "$ADVICE_REPO" \
        | grep -qv 'exported = false'
}

# BLAST-RADIUS: entity lookups must stay exported — this ticket authorised exactly
# three removals, not a sweep.
check_C5_entity_lookups_still_exported() {
    [ -f "$ADVICE_REPO" ] || return 1
    ! grep -E '@RestResource\(path = "(findByExternalid|findByTransferId|findByState|findByKeywordAndState)"' "$ADVICE_REPO" \
        | grep -q 'exported = false'
}

# === Fix D — outbound BOL "shipped" is date-only ==============================

check_D_shipped_time_gone() {
    file_not_contains 'getTimeDate\(outboundBol\.shipped\)' "$BOL_DETAILS"
}

check_D_shipped_still_rendered() {
    file_contains 'outboundBol\.shipped' "$BOL_DETAILS"
}

# ANTI-OVER-FIX: `created` IS a timestamptz — it must keep its time.
check_D_created_keeps_time() {
    file_contains 'getTimeDate\(outboundBol\.created\)' "$BOL_DETAILS"
}

# === Guards — things that are ALREADY correct and must stay that way ==========

# G1: PR #116 / dfe24f8 must still be in place. If someone reverts it, defect (a)
# (wrong calendar day) returns and this whole plan's premise breaks.
check_G1_viewdto_tolocaldate_dayofdelivery() {
    file_contains 'dto\.put\("dayofdelivery", toLocalDate\(result\.getDayofdelivery\(\)\)\)' "$VIEW_DTO"
}

check_G1b_viewdto_tolocaldate_until() {
    file_contains 'dto\.put\("dayofdeliveryuntil", toLocalDate\(result\.getDayofdeliveryuntil\(\)\)\)' "$VIEW_DTO"
}

# G2: the notice DETAIL screen has always been date-only — it is the reference
# implementation Fix A copies. It must not acquire a getTime sibling.
check_G2_detail_still_date_only() {
    file_contains 'getDate\(noticeDetails\.dayofdelivery\)' "$OPEN_DESC" \
        && file_not_contains 'getTime\(noticeDetails\.dayofdelivery\)' "$OPEN_DESC"
}

# G3: the Excel export's LocalDate branch (date-only, never tz-converted) must survive.
check_G3_export_localdate_branch() {
    file_contains 'cellContent instanceof LocalDate' "$FILE_EXPORT"
}

# === Wire into the runner ====================================================

echo
echo "verify-SBDEV-2781 — Expected Return Date is date-only"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

echo "GUARD (Fix A already on origin/develop via e6ca85a) — Open Inbound Notices Expected cell"
run A1a  "date still rendered"                       check_A1_open_keeps_date
run A1b  "stray getTime(dayofdelivery) removed"      check_A1_open_time_gone
run A1c  "Expected column still declared"            check_A1_open_column_intact

echo
echo "GUARD (Fix A already on origin/develop via e6ca85a) — Closed Inbound Notices Expected cell"
run A2a  "date still rendered"                       check_A2_closed_keeps_date
run A2b  "stray getTime(dayofdelivery) removed"      check_A2_closed_time_gone
run A2c  "Expected column still declared"            check_A2_closed_column_intact
run A2d  "Closed column KEEPS its real time"         check_A2_closed_modified_keeps_time
run A2e  "getTime() method retained (used by modified)" check_A2_closed_gettime_method_kept

echo
echo "Fix B — dead dayofdelivery slot"
run B1   "dead slot removed from receipt table"      check_B_dead_slot_gone
run B2   "receipt table otherwise intact"            check_B_table_intact

echo
echo "Fix C — HAL search resources unexported"
run C1   "getDetailViewByKeyword exported=false"     check_C1_detailview_unexported
run C2   "getOpenNoticesByKeyword exported=false"    check_C2_open_unexported
run C3   "getClosedNoticesByKeyword exported=false"  check_C3_closed_unexported
run C4   "no bare export left on the three"          check_C4_no_bare_export_left
run C5   "entity lookups still exported"             check_C5_entity_lookups_still_exported

echo
echo "Fix D — outbound BOL shipped"
run D1   "stray getTimeDate(shipped) removed"        check_D_shipped_time_gone
run D2   "shipped still rendered"                    check_D_shipped_still_rendered
run D3   "created KEEPS its real time"               check_D_created_keeps_time

echo
echo "Guards — already-correct behaviour must not regress"
run G1a  "ViewDtoService toLocalDate(dayofdelivery)" check_G1_viewdto_tolocaldate_dayofdelivery
run G1b  "ViewDtoService toLocalDate(...until)"      check_G1b_viewdto_tolocaldate_until
run G2   "notice detail still date-only"             check_G2_detail_still_date_only
run G3   "Excel export LocalDate branch intact"      check_G3_export_localdate_branch

echo
echo "Behavioural tests (code-shape greps prove the call exists, not that it works)"
if have_jest; then
    run T1   "GUARD dateFormatter spec passes"           jest_spec_passes "dateFormatter"
    run T2   "GUARD Expected-column spec passes"         jest_spec_passes "inboundNoticesExpectedColumn"
    run T5   "GATE outbound BOL shipped spec passes"     jest_spec_passes "outboundBolShippedDate"
    run T6   "GATE receipt-table dead-slot spec passes"  jest_spec_passes "openNoticeReceiptTableDeadSlot"
else
    skip T1  "GUARD dateFormatter spec passes"           "jest not installed — run 'yarn install' in $UI"
    skip T2  "GUARD Expected-column spec passes"         "jest not installed — run 'yarn install' in $UI"
    skip T5  "GATE outbound BOL shipped spec passes"     "jest not installed — run 'yarn install' in $UI"
    skip T6  "GATE receipt-table dead-slot spec passes"  "jest not installed — run 'yarn install' in $UI"
fi
if have_mvn; then
    run T3   "AdviceRepositoryRestExportUnitTest passes" mvn_test_passes AdviceRepositoryRestExportUnitTest
    run T4   "ViewDtoServiceUnitTest still green (PR#116 guard)" mvn_test_passes ViewDtoServiceUnitTest
else
    skip T3  "AdviceRepositoryRestExportUnitTest passes" "mvn not on PATH — export SDKMAN java+maven"
    skip T4  "ViewDtoServiceUnitTest still green"        "mvn not on PATH — export SDKMAN java+maven"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
