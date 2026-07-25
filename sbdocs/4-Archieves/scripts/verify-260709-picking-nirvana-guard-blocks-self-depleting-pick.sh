#!/usr/bin/env bash
# verify-260709-picking-nirvana-guard-blocks-self-depleting-pick.sh
#
# Machine-checkable acceptance for
#   sbdocs/1-Projects/wms1/plan/260709-picking-nirvana-guard-blocks-self-depleting-pick.md
#
# Fix A: in PickingorderBusinessService.confirmPick, the completing pick line's
# pickfromstockunit_id must be nulled (and saved) BEFORE the transferStockToUnitLoad
# call, so the SBDEV-2481 send-to-nirvana guard (StockunitBusinessService:323) does not
# treat the self-depleting pick as an orphaning move. The old post-transfer null must be
# gone.
#
# Run after every implementation pass:
#   $ bash sbdocs/9-System/scripts/verify-260709-picking-nirvana-guard-blocks-self-depleting-pick.sh
#
# Exit code 0 iff all checks pass. Override PROJECT_ROOT for a different checkout.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v1/wms-api}"
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

file_contains() { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { ! grep -qE "$1" "$2" 2>/dev/null; }

SVC=src/main/java/net/aim_ai/wms/service
PBS=$SVC/PickingorderBusinessService.java

# --- Ordering assertion helpers ----------------------------------------------
# Helpers use grep -n | cut to compare the line numbers of the anchor statements
# WITHIN confirmPick, so a stray occurrence elsewhere in the file cannot fool us.

# Line number of the FIRST setPickfromstockunitId(null) occurrence.
line_of_null() {
    grep -nE 'setPickfromstockunitId\(null\)' "$PBS" 2>/dev/null | head -1 | cut -d: -f1
}
# Line number of the FIRST transferStockToUnitLoad( call.
line_of_transfer() {
    grep -nE 'transferStockToUnitLoad\(' "$PBS" 2>/dev/null | head -1 | cut -d: -f1
}
# Line number of the LAST setPickfromstockunitId(null) occurrence.
line_of_last_null() {
    grep -nE 'setPickfromstockunitId\(null\)' "$PBS" 2>/dev/null | tail -1 | cut -d: -f1
}
# Line number of the FIRST read of the FK (getPickfromstockunitId()), i.e. the
# findById(...) dereference that loads the source stock unit (~:268). The null must
# land AFTER this, or moving it earlier would break stockUnit loading.
line_of_fk_read() {
    grep -nE 'getPickfromstockunitId\(\)' "$PBS" 2>/dev/null | head -1 | cut -d: -f1
}

# POSITIVE: the (first) null-and-save precedes the (first) transfer call.
check_null_before_transfer() {
    local n t
    n=$(line_of_null); t=$(line_of_transfer)
    [ -n "$n" ] && [ -n "$t" ] && [ "$n" -lt "$t" ]
}

# POSITIVE: the null lands AFTER the FK read (findById dereference), so it did not get
# hoisted above the stockUnit load. Guards against the FIXA-2 false-green on misplacement.
check_null_after_fk_read() {
    local n r
    n=$(line_of_null); r=$(line_of_fk_read)
    [ -n "$n" ] && [ -n "$r" ] && [ "$n" -gt "$r" ]
}

# The FK is nulled at all in confirmPick.
check_null_present() {
    file_contains 'setPickfromstockunitId\(null\)' "$PBS"
}

# NEGATIVE: there is no setPickfromstockunitId(null) occurring AFTER the transfer call
# (i.e. the old post-transfer null is gone). If a null exists, its LAST occurrence must
# still be before the transfer.
check_no_post_transfer_null() {
    local last t
    last=$(line_of_last_null); t=$(line_of_transfer)
    [ -n "$last" ] && [ -n "$t" ] && [ "$last" -lt "$t" ]
}

# Guard site is intact (context sanity — we did NOT touch the guard).
check_guard_untouched() {
    file_contains 'findByPickfromstockunitId\(' "$SVC/StockunitBusinessService.java" \
    && file_contains '\.isEmpty\(\)' "$SVC/StockunitBusinessService.java" \
    && file_contains 'ACTIVE_PICK_MESSAGE' "$SVC/StockunitBusinessService.java"
}

# --- Targeted unit test -------------------------------------------------------
mvn_test_passes() {
    local cls=$1
    mvn test -Dtest="$cls" -DfailIfNoTests=false >/dev/null 2>&1
}

echo
echo "verify-260709 — self-depleting-pick nirvana-guard fix acceptance"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

run FIXA-1  "Fix A — confirmPick still nulls pickfromstockunit_id"        check_null_present
run FIXA-2  "Fix A — null precedes transferStockToUnitLoad call (POSITIVE)" check_null_before_transfer
run FIXA-2b "Fix A — null lands AFTER the FK read/findById (not hoisted too far)" check_null_after_fk_read
run FIXA-3  "Fix A — no post-transfer null remains (NEGATIVE)"            check_no_post_transfer_null
run CTX-1   "Context — SBDEV-2481 nirvana guard left intact"             check_guard_untouched

echo

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T-PBS "T — PickingorderBusinessServiceUnitTest passes" mvn_test_passes PickingorderBusinessServiceUnitTest
else
    skip T-PBS "PickingorderBusinessServiceUnitTest" "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
