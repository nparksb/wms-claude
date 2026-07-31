#!/usr/bin/env bash
# verify-SBDEV-2777-stock-history-client-id-blind-mis-aggregation.sh   [revision 3]
#
# Machine-checkable acceptance for SBDEV-2777 — stock_history() is client_id-blind.
# Plan: sbdocs/1-Projects/wms2/plan/SBDEV-2777-stock-history-client-id-blind-mis-aggregation.md
#
#   PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
#     bash sbdocs/9-System/scripts/verify-SBDEV-2777-stock-history-client-id-blind-mis-aggregation.sh
#
# Exit 0 ONLY on "N pass, 0 fail, 0 skip". Paste that line in the end-of-task report.
#
# ── r2 changes (ralplan round 1 found six defects in r1 of this script) ──────
#   1. ONE migration: V2.2.07 (Fix A + Fix B). r3 collapsed r2's two-migration scheme
#      (no -target in the runbook, so it delivered nothing) and dropped the V2.1.18/19
#      onboarding mirrors (dead files — nothing executes them).
#   2. SKIP is now a FAIL. r1 exited 0 with the behavioural gate skipped, and its
#      acceptance string ("N pass, 0 fail") was one r1 never printed. P5 violation.
#   3. mvn_test_passes no longer uses -q — that suppressed the INFO lines carrying
#      BUILD SUCCESS and Surefire's "Tests run:", so it could NEVER match on a
#      passing run. Guaranteed false-FAIL. Also exports SDKMAN PATH and surfaces
#      output on failure.
#   4. All negative checks are gated on the migration existing. `! grep` on a
#      missing file exits 2 and inverts to TRUE — r1's negatives passed vacuously.
#   5. B1/B2 are position-anchored inside their own CASE expression, so swapping
#      the two activitycode pairs between `received` and `adjustments` now fails.
#      r1 was file-scoped and a swap scored 21 pass / 0 fail.
#   6. Added guards r1 lacked entirely: LEFT JOIN preserved, `WHERE sr.created > $1`,
#      `USING $1`, the RETURN / CYCLE_COUNT / MANAGE_INVENTORY branches, exactly one
#      CREATE OR REPLACE, and the `myanswer` positional-binding landmine.
#
# ── r3 fixes to this script ──────────────────────────────────────────────────
#   - Dropped the duplicated A-loop: r2 ran 19 shape checks against V2.2.07, a body that
#     never survived on any tenant that finished migrating. ~50 checks -> ~26.
#   - Dropped M1/M2 (mirror byte-identity) — the mirrors no longer exist.
#   - count_matches: removed `|| echo 0`. `grep -c` prints 0 AND exits 1 on no match, so
#     the fallback appended a second 0 and the arithmetic test threw. It landed on FAIL by
#     accident, which is not the same as working.
#   - Widened the Fix-B anchor windows 200 -> 400 chars. At 200 they measured ~101/~91
#     against real indentation and would false-FAIL a correct fix if the pair were inserted
#     anywhere but last in its CASE. 400 is still ~200 short of crossing into the adjacent
#     CASE, so swap detection survives. §5 also now mandates "append last".
#     NOTE the \\b anchors: at 400 chars the window reaches `AS received_recordset`, which
#     `AS received` prefix-matches — that made the swap sabotage FALSE-PASS until caught.
#   - Removed the header's claim of a "version collision" check that was never implemented.
#
# ── What this proves, and what it does not ───────────────────────────────────
# CODE SHAPE only. Acceptance ALSO requires the plan's §8.3 before/after capture of
# stock_history()'s own output per tenant — that is what proves the arithmetic moved,
# and moved only where predicted. A green run here with §8.3 unrun is NOT acceptance.
#
# ── Run it BEFORE the fix ────────────────────────────────────────────────────
# Against the pre-fix tree this MUST report many FAILs. If it passes before the fix,
# the checks are wrong — fix them, not the code.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

file_contains()        { grep -qE "$1" "$2"; }
file_not_contains()    { ! grep -qE "$1" "$2"; }
file_contains_ml()     { tr '\n' ' ' < "$2" | grep -qE "$1"; }
file_not_contains_ml() { ! tr '\n' ' ' < "$2" | grep -qE "$1"; }

# Count occurrences of a regex.
count_matches() { grep -cE "$1" "$2" 2>/dev/null; }   # r3: no `|| echo 0` — see header

# r2: -q removed (it hid BUILD SUCCESS and "Tests run:"), SDKMAN exported, output
# surfaced on failure so a FAIL is diagnosable.
mvn_test_passes() {
    local cls=$1 out
    # sdkman-init.sh references unbound variables; under this script's `set -u` that exits the
    # WHOLE shell (127) before Result: is ever printed. Only reachable once the IT file exists,
    # which is why earlier runs looked clean. Disarm -u across the source, then restore it.
    set +u
    [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] && . "$HOME/.sdkman/bin/sdkman-init.sh" >/dev/null 2>&1
    set -u
    command -v mvn >/dev/null 2>&1 || { echo "mvn not on PATH (SDKMAN not initialised?)" >&2; return 1; }
    out=$(mvn test -Dtest="$cls" -DfailIfNoTests=false 2>&1)
    if grep -qE "BUILD SUCCESS" <<<"$out" && grep -qE "Tests run: [0-9]+, Failures: 0, Errors: 0" <<<"$out"; then
        return 0
    fi
    printf '%s\n' "$out" | tail -25 >&2
    return 1
}

MIG_DIR="src/main/resources/db/migration"
ONB_DIR="src/main/resources/db/v1-to-v2-onboarding/schema"

# Resolve by version prefix, NOT by description suffix. r1 globbed on the exact
# description, so a correct fix under a slightly different filename made the glob
# miss and every negative check pass vacuously.
resolve_one() { # <dir> <version-prefix>
    local d=$1 v=$2 hits
    hits=$(ls "$d"/${v}__*.sql 2>/dev/null | wc -l)
    [ "$hits" -eq 1 ] || return 1          # 0 = missing, >1 = ambiguous duplicate
    ls "$d"/${v}__*.sql
}
MIG="$(resolve_one "$MIG_DIR" 'V2.2.07' || true)"; : "${MIG:=/nonexistent}"

# ── structural checks, per migration ────────────────────────────────────────
mig_exists()        { [ -f "$1" ]; }
mig_create()        { file_contains 'CREATE OR REPLACE FUNCTION public\.stock_history' "$1"; }
mig_no_drop()       { file_not_contains 'DROP FUNCTION' "$1"; }
mig_signature()     { file_contains 'stock_history\(as_of_date (timestamptz|timestamp with time zone)\)' "$1"; }
mig_returns()       { file_contains 'RETURNS TABLE\(item_id bigint, item_nr character varying, total_stock_today numeric, received numeric, returned numeric, shipped bigint, adjustments numeric, historical_stock numeric\)' "$1"; }
# Exactly one function replaced — a migration that also rewrites the siblings
# silently expands blast radius past the plan's premise.
mig_single_create() { [ "$(count_matches '^CREATE OR REPLACE FUNCTION' "$1")" -eq 1 ]; }

# ── Fix A ───────────────────────────────────────────────────────────────────
a_select()      { file_contains 'sr\.client_id\s+AS client_id' "$1"; }
a_group()       { file_contains 'GROUP BY sr\.itemdata, sr\.client_id' "$1"; }
a_join()        { file_contains 'received_recordset\.client_id\s*=\s*sv\.client_id' "$1"; }
a_blind_group() { file_not_contains 'GROUP BY sr\.itemdata\)' "$1"; }
a_blind_join()  { file_not_contains_ml 'ON received_recordset\.itemdata = sv\.item_nr\s+LEFT JOIN' "$1"; }
# r2: the received_recordset join must STILL be a LEFT JOIN. Converting it to an
# inner join silently drops stock_view rows with no post-cutoff stockrecords and
# passes every other check.
a_left_join()   { file_contains_ml 'LEFT JOIN \(SELECT\s+sr\.itemdata' "$1"; }

# ── Fix B — position-anchored inside the correct CASE ───────────────────────
# r2: a swap between the two sums scored 21/0 in r1. Anchor each pair to the text
# between its own CASE and its own AS alias.
b_received_pair() {
    tr '\n' ' ' < "$1" | grep -qE "STOCK_REMOVED'' AND sr\.type = ''STOCK_ALTERED''.{0,400}AS received\\b"
}
b_adjust_pair() {
    tr '\n' ' ' < "$1" | grep -qE "MANUAL_REMOVAL'' AND sr\.type = ''STOCK_ALTERED''.{0,400}AS adjustments\\b"
}
b_quotes_ok() {
    file_not_contains "[^']'(RECEIVING|STOCK_ALTERED|STOCK_REMOVED|MANUAL_REMOVAL|CYCLE_COUNT|MANAGE_INVENTORY|RETURN|CLOSED)'[^']" "$1"
}

# ── preserved behaviour — everything that must NOT change ───────────────────
p_all_shipped()  { file_contains 'GROUP BY bp\.itemdata_id\) all_shipped' "$1" && file_contains 'sv\.item_id = all_shipped\.bpid' "$1"; }
p_formula()      { file_contains '\(total_stock_today - received - returned \+ shipped - adjustments\) AS historical_stock' "$1"; }
p_created_gate() { file_contains 'WHERE sr\.created > \$1' "$1"; }   # r2
p_using()        { file_contains 'USING \$1;' "$1"; }                # r2
# r2: r1 asserted only 4 of the 7 pre-existing branches. Dropping RETURN,
# CYCLE_COUNT or MANAGE_INVENTORY is a silent arithmetic change that scored 21/0.
p_branches() {
    file_contains "sr\.activitycode = ''RECEIVING''" "$1" &&
    file_contains "sr\.activitycode = ''STOCK_ALTERED'' AND sr\.type = ''STOCK_ALTERED''" "$1" &&
    file_contains "sr\.activitycode = ''STOCK_REMOVED'' AND sr\.type = ''STOCK_REMOVED''" "$1" &&
    file_contains "sr\.activitycode = ''MANUAL_REMOVAL'' AND sr\.type = ''STOCK_REMOVED''" "$1" &&
    file_contains "sr\.activitycode = ''RETURN''" "$1" &&
    file_contains "sr\.activitycode = ''CYCLE_COUNT'' AND sr\.type = ''STOCK_ALTERED''" "$1" &&
    file_contains "sr\.activitycode = ''MANAGE_INVENTORY''" "$1"
}
# r2: the myanswer positional-binding landmine. RETURN QUERY binds to RETURNS TABLE
# positionally through `SELECT *`, so any extra column in the inner projection is a
# runtime "structure of query does not match function result type" on every report.
# NB the shipped body puts `*,` on its own line after SELECT, so \s+ between them
# is required — an adjacent-match regex false-FAILs a correct implementation.
p_myanswer_shape() {
    file_contains_ml 'SELECT\s+\*,\s*\(total_stock_today' "$1" &&
    file_not_contains_ml 'sv\.client_id\s+AS client_id' "$1"
}

# ── no-Java-change assertions ───────────────────────────────────────────────
SVR="src/main/java/net/aim_ai/wms/repo/jpa/StockViewRepository.java"
SRR="src/main/java/net/aim_ai/wms/repo/jpa/StockrecordRepository.java"
CR="src/main/java/net/aim_ai/wms/repo/jpa/ClientRepository.java"
PROJ="src/main/java/net/aim_ai/wms/repo/projection/StockHistoryView.java"
j_stockview()  { file_contains 'from stock_history\(:asOfDate\)' "$SVR"; }
j_stockrecord(){ file_contains 'from transaction_detail\(:clientNumber, :sku, :startdate, :enddate\)' "$SRR" &&
                 file_contains 'from transaction_summary\(:clientNumber, :startdate, :enddate\)' "$SRR"; }
j_client()     { file_contains 'from transaction_summary\(:clientCode,' "$CR" &&
                 file_contains 'from transaction_detail\(:clientCode, :sku,' "$CR"; }
j_projection() { file_contains 'BigDecimal getReceived\(\);' "$PROJ" &&
                 file_contains 'BigDecimal getAdjustments\(\);' "$PROJ" &&
                 file_contains 'BigDecimal getHistorical_stock\(\);' "$PROJ"; }
d3_base_dump() { ! grep -qE 'GROUP BY sr\.itemdata, sr\.client_id' "$MIG_DIR/V2.2.00__base_v2_schema.sql"; }

echo
echo "verify-SBDEV-2777 r3 — stock_history client_id aggregation (single migration)"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  V2.2.07 : ${MIG#$MIG_DIR/}"
echo

run C1 "migration present (exactly one V2.2.07 match)" mig_exists "$MIG"
if [ ! -f "$MIG" ]; then
    # Gate everything else on existence: `! grep` on a missing file exits 2 and inverts
    # to TRUE, so the negative checks would otherwise pass vacuously.
    printf "  FAIL  %-10s  %s\n" "C*" "remaining checks not run — migration absent"
    FAIL=$((FAIL+1))
else
    run C2  "CREATE OR REPLACE stock_history"          mig_create      "$MIG"
    run C3  "no DROP FUNCTION"                          mig_no_drop     "$MIG"
    run C4  "signature unchanged (as_of_date tstz)"     mig_signature   "$MIG"
    run C5  "RETURNS TABLE unchanged"                   mig_returns     "$MIG"
    run C6  "exactly one CREATE OR REPLACE"             mig_single_create "$MIG"
    echo
    run A1  "Fix A — client_id selected"                a_select        "$MIG"
    run A2  "Fix A — GROUP BY itemdata, client_id"      a_group         "$MIG"
    run A3  "Fix A — join predicate on client_id"       a_join          "$MIG"
    run A4  "Fix A — blind GROUP BY gone"               a_blind_group   "$MIG"
    run A5  "Fix A — blind join gone"                   a_blind_join    "$MIG"
    run A6  "Fix A — received join still LEFT JOIN"     a_left_join     "$MIG"
    echo
    run B1  "Fix B — STOCK_REMOVED/ALTERED in *received*"     b_received_pair "$MIG"
    run B2  "Fix B — MANUAL_REMOVAL/ALTERED in *adjustments*" b_adjust_pair   "$MIG"
    run B3  "EXECUTE-string quotes doubled"                   b_quotes_ok     "$MIG"
    echo
    run P1  "preserved — all_shipped untouched"         p_all_shipped   "$MIG"
    run P2  "preserved — historical_stock formula"      p_formula       "$MIG"
    run P3  "preserved — WHERE sr.created > \$1"         p_created_gate  "$MIG"
    run P4  "preserved — USING \$1"                      p_using         "$MIG"
    run P5  "preserved — all 7 activitycode branches"   p_branches      "$MIG"
    run P6  "myanswer projection unchanged"             p_myanswer_shape "$MIG"
fi
echo
echo "── no Java change"
run J1 "StockViewRepository caller intact"  j_stockview
run J2 "Stockrecord callers intact"         j_stockrecord
run J3 "Client callers intact"              j_client
run J4 "StockHistoryView shape intact"      j_projection
run D3 "base dump left untouched (D3)"      d3_base_dump
echo
echo "── behavioural gate"
# Must be named *IntegrationTest: Surefire EXCLUDES that pattern (pom.xml:448-451) and
# Failsafe INCLUDES it (:565-568), so it runs under `mvn verify` -> target/failsafe-reports/.
# A *IT.java name would never execute at all (27 such files, 0 reports).
IT="src/test/java/net/aim_ai/wms/integration/StockHistoryClientIsolationIntegrationTest.java"
run T0 "integration test file present (…IntegrationTest)" test -f "$IT"
if [ -f "$IT" ]; then
    run T1 "integration test passes" mvn_test_passes StockHistoryClientIsolationIntegrationTest
else
    printf "  FAIL  %-10s  %s\n" "T1" "integration test absent — behavioural gate cannot run"
    FAIL=$((FAIL+1))
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
echo
echo "REMINDER: code shape only. Acceptance also requires the plan's section 8.3"
echo "          before/after capture of stock_history() output, per tenant."

[ "$FAIL" -eq 0 ] && [ "$SKIP" -eq 0 ]
