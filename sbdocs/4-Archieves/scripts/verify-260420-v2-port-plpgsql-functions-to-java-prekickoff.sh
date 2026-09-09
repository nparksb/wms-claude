#!/usr/bin/env bash
# verify-260420-v2-port-plpgsql-functions-to-java-prekickoff.sh
# PRE-KICKOFF baseline gate for plan 260420-v2-port-plpgsql-functions-to-java.md.
#
# This is NOT the usual post-implementation acceptance guard. It machine-checks
# the plan's BASELINE ASSUMPTIONS before any code is written, encoding the N1
# kickoff gate the reviewers required: the report-function port baselines on
# `V1.2.05__utc_update_functions.sql`, which ships via PR #47 (feature/utc-timezone)
# and is NOT on develop yet. Run this at Phase A kickoff:
#   - if the GATE check (C2) FAILS, PR #47 has not merged — DO NOT start Phase A.
#   - if a PROVENANCE check (C4) FAILS, V1.2.05 changed in review — re-validate
#     §2.2.1 and re-baseline §2.2/§3.2 before porting (or use the pre-UTC fallback).
#
#   $ PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
#       bash sbdocs/9-System/scripts/verify-260420-v2-port-plpgsql-functions-to-java-prekickoff.sh
#
# Exit 0 iff every check passes (= safe to start P2 Phase A on the V1.2.05 baseline).
# Until PR #47 is merged to develop, C2 is EXPECTED to FAIL — that is the gate working.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
DEVELOP_REF="${DEVELOP_REF:-origin/develop}"

cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0
run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi
}
note() { printf "  ----  %-10s  %s\n" "$1" "$2"; }

MIGDIR=src/main/resources/db/migration
V1205="$MIGDIR/V1.2.05__utc_update_functions.sql"
V2107="$MIGDIR/V2.1.07__update_transaction_detail_pick_amount_filter.sql"
V1104="$MIGDIR/V1.1.04__wms_functions.sql"
V1003="$MIGDIR/V1.0.03__wms_functions.sql"
CLIENTREPO=src/main/java/net/aim_ai/wms/repo/jpa/ClientRepository.java

file_contains() { grep -qE "$1" "$2" 2>/dev/null; }
exists()        { [ -f "$1" ]; }

# Extract the EXECUTE string body (between the lone-quote delimiters) of the
# function whose CREATE line matches the given regex. The body uses $N positional
# params, so it is identical across the timestamp/timestamptz signature variants.
extract_body() {
    awk -v re="$2" -v q="'" '
        $0 ~ re { found=1 }
        found && $0 ~ ("^[[:space:]]*" q "[[:space:]]*$") {
            qc++
            if (qc==1) { capt=1; next }
            if (qc==2) { exit }
        }
        capt { print }
    ' "$1"
}
body_identical() { diff <(extract_body "$1" "$2") <(extract_body "$3" "$4") >/dev/null 2>&1; }

echo "== P2 (PL/pgSQL -> Java report port) PRE-KICKOFF baseline gate =="
echo "PROJECT_ROOT=$PROJECT_ROOT   develop ref=$DEVELOP_REF"
echo

# --- C1: V1.2.05 present in the working tree (sanity) ---
check_C1() { exists "$V1205"; }
run C1 "V1.2.05__utc_update_functions.sql present in working tree" check_C1

# --- C2: GATE — V1.2.05 merged to develop (PR #47). Expected FAIL until #47 lands. ---
git fetch "$(echo "$DEVELOP_REF" | cut -d/ -f1)" >/dev/null 2>&1 || true
check_C2() { git ls-tree -r --name-only "$DEVELOP_REF" -- "$MIGDIR" 2>/dev/null | grep -q "V1.2.05__utc_update_functions.sql"; }
run C2-GATE "PR #47 merged: V1.2.05 exists on $DEVELOP_REF (DO NOT start Phase A until PASS)" check_C2

# --- C3: V1.2.05 carries timestamptz signatures + drops the old timestamp sigs ---
check_C3_history() { file_contains "CREATE OR REPLACE FUNCTION (public\.)?stock_history\(as_of_date timestamptz\)" "$V1205"; }
check_C3_detail()  { file_contains "CREATE OR REPLACE FUNCTION public\.transaction_detail\(.*timestamptz, .*timestamptz\)" "$V1205"; }
check_C3_summary() { file_contains "CREATE OR REPLACE FUNCTION public\.transaction_summary\(.*timestamptz, .*timestamptz\)" "$V1205"; }
check_C3_drops()   { file_contains "DROP FUNCTION IF EXISTS public\.transaction_detail\(.*timestamp without time zone" "$V1205"; }
run C3-hist "stock_history(as_of_date timestamptz) signature"        check_C3_history
run C3-det  "transaction_detail(..., timestamptz, timestamptz) sig"  check_C3_detail
run C3-sum  "transaction_summary(..., timestamptz, timestamptz) sig" check_C3_summary
run C3-drop "old timestamp-without-tz signatures dropped first"       check_C3_drops

# --- C4: PROVENANCE — V1.2.05 bodies are byte-identical to latest pre-UTC sources (plan §2.2.1) ---
check_C4_history() { body_identical "$V1003" "CREATE OR REPLACE FUNCTION (public\.)?stock_history\("       "$V1205" "CREATE OR REPLACE FUNCTION (public\.)?stock_history\("; }
check_C4_detail()  { body_identical "$V2107" "CREATE OR REPLACE FUNCTION public\.transaction_detail\("     "$V1205" "CREATE OR REPLACE FUNCTION public\.transaction_detail\("; }
check_C4_summary() { body_identical "$V1104" "CREATE OR REPLACE FUNCTION public\.transaction_summary\("    "$V1205" "CREATE OR REPLACE FUNCTION public\.transaction_summary\("; }
check_C4_filter()  { file_contains "sr\.amount != 0" "$V1205"; }   # the V2.1.07 zero-amount PICKING filter must be present
run C4-hist "stock_history body == V1.0.03 (byte-identical)"                check_C4_history
run C4-det  "transaction_detail body == V2.1.07 (byte-identical)"          check_C4_detail
run C4-sum  "transaction_summary body == V1.1.04 (byte-identical)"         check_C4_summary
run C4-filt "zero-amount PICKING filter (sr.amount != 0) present in V1.2.05" check_C4_filter

# --- C5: UTC Phase 2.10 — ClientRepository report casts are timestamptz ---
# (native-query strings escape '::' as '\:\:', so match to_timestamp + timestamptz on the line)
check_C5() { [ "$(grep -cE 'to_timestamp.*timestamptz' "$CLIENTREPO")" -ge 4 ]; }
run C5 "ClientRepository to_timestamp(...) -> timestamptz casts present (>=4)" check_C5

# --- C6: migration numbering — V2.1.15/16 present (from #47); V2.1.17/18 free for drop/restore ---
check_C6_1516() { ls "$MIGDIR"/V2.1.15__* "$MIGDIR"/V2.1.16__* >/dev/null 2>&1; }
check_C6_1718() { ! ls "$MIGDIR"/V2.1.17__* "$MIGDIR"/V2.1.18__* >/dev/null 2>&1; }
run C6-1516 "V2.1.15 + V2.1.16 present (PR #47)"          check_C6_1516
run C6-1718 "V2.1.17 + V2.1.18 free (P2 drop/restore)"   check_C6_1718
NEXTFREE="$(ls "$MIGDIR" | grep -oE '^V2\.1\.[0-9]+' | sort -V | tail -1)"
note C6-head "highest V2.1.x in working tree: ${NEXTFREE:-none} (re-derive next-free at execution time)"

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
if [ "$FAIL" -eq 0 ]; then
    echo "GATE OPEN: V1.2.05 baseline verified — safe to start P2 Phase A."
else
    echo "GATE CLOSED: $FAIL check(s) failed. If only C2-GATE failed, PR #47 is not yet"
    echo "merged to develop — do NOT start P2 Phase A. If a C4 provenance check failed,"
    echo "V1.2.05 diverged from its pre-UTC source — re-validate plan §2.2.1 before porting."
fi
[ "$FAIL" -eq 0 ]
