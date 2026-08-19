#!/usr/bin/env bash
# verify-SBDEV-2890-transaction-detail-ul-picks-excluded-v1.sh   [revision 1]
#
# Machine-checkable acceptance for SBDEV-2890 (v1/wms-api) — transaction_detail()
# excludes every full-move unit-load pick. Same one-line defect as v2, live in v1
# production, and v1 is where it originated (V1.26.28/V1.1.08 re-broke SBDEV-1319).
#
# Plan: sbdocs/1-Projects/wms1/plan/SBDEV-2890-transaction-detail-ul-picks-excluded.md
#
#   PROJECT_ROOT=/Users/np1076/dev/spk/owl/v1/wms-api \
#     bash sbdocs/9-System/scripts/verify-SBDEV-2890-transaction-detail-ul-picks-excluded-v1.sh
#
# Exit 0 ONLY on "N pass, 0 fail, 0 skip".
#
# ── THIS IS NOT A COPY OF THE v2 SCRIPT. Four things genuinely differ ───────
#   1. Migration: V1.26.32 (ancestor V1.1.08). NOT V1.1.10 — Flyway compares version
#      parts NUMERICALLY, so [1,26,31] > [1,1,9] and the V1.26.x block is the tail.
#      V1.1.10 would sort BEFORE it and be rejected as out-of-order on migrated tenants.
#   2. Signature: `timestamp WITHOUT time zone`. v2 uses `with time zone`. Getting this
#      wrong makes CREATE OR REPLACE produce an OVERLOAD instead of replacing — the
#      broken function stays live and callable while the fix sits inertly beside it.
#      This is the highest-severity v1-only hazard, checked at S5 and H1.
#   3. Test suffix: `...IT.java`. v1 Surefire EXCLUDES **/*IT.java (pom.xml:541) and
#      Failsafe INCLUDES it (pom.xml:644) — the exact inverse of v2. A file named
#      ...IntegrationTest.java in THIS repo NEVER RUNS.
#   4. NO SBDEV-2801 NULL-hardening checks. That fix was v2-only (V2.2.08). Asserting
#      the six coalesces here would false-FAIL a correct v1 fix. See plan §8.3 caveat.
#
# ── Idiom inherited from verify-SBDEV-2777 (r3) ─────────────────────────────
#   SKIP counts as FAIL. Migrations resolve by version prefix, not description.
#   Negative checks are gated on file existence (`! grep` on a missing file inverts
#   to TRUE — that produced four vacuous PASSes in r1 of the v2 script). mvn runs
#   without -q and disarms `set -u` around sdkman-init.sh.
#
# ── What this proves, and what it does NOT ──────────────────────────────────
# CODE SHAPE only. Acceptance ALSO requires mvn verify green, the plan's §8.5 manual
# plan (scenarios 1-3 AND 7 — 7 is the pg_proc count that proves the overload hazard
# was avoided), and the §11 sizing query recorded (plan is db_verified: false).
#
# ── Run it BEFORE the fix ───────────────────────────────────────────────────
# Must report many FAILs against the pre-fix tree. If it passes, the checks are wrong.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/Users/np1076/dev/spk/owl/v1/wms-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0

# Diagnostics captured, surfaced only on failure (r1 discarded mvn's tail -25).
run() {
    local id=$1 desc=$2 out; shift 2
    out=$("$@" 2>&1)
    if [ $? -eq 0 ]; then
        printf "  PASS  %-8s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-8s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
        [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/          | /' >&2
    fi
}

file_contains()        { grep -qE "$1" "$2"; }
file_contains_ml()     { tr '\n' ' ' < "$2" | grep -qE "$1"; }
count_matches()        { grep -cE "$1" "$2" 2>/dev/null; }
file_not_contains()    { [ -f "$2" ] && ! grep -qE "$1" "$2"; }
file_not_contains_ml() { [ -f "$2" ] && ! tr '\n' ' ' < "$2" | grep -qE "$1"; }

# ── COMMENT-BLIND MATCHING — every structural assertion must use these ─────────
# Matching the RAW file is wrong in BOTH directions: a header that documents the change
# (which the plan REQUIRES, since no inline comment may go in the EXECUTE body) quotes the
# OLD predicate and false-FAILS a correct fix; and a header copied from the ancestor can
# false-PASS a body that was never fixed. See the v2 script for the worked example.
strip_comments()  { sed 's/--.*$//' "$1"; }
body()            { [ -f "$2" ] && strip_comments "$2" | grep -qE "$1"; }
body_not()        { [ -f "$2" ] && ! strip_comments "$2" | grep -qE "$1"; }
body_ml()         { [ -f "$2" ] && strip_comments "$2" | tr '\n' ' ' | grep -qE "$1"; }
body_not_ml()     { [ -f "$2" ] && ! strip_comments "$2" | tr '\n' ' ' | grep -qE "$1"; }
body_count()      { strip_comments "$1" | grep -cE "$2" 2>/dev/null; }

mvn_verify_passes() {
    local cls=$1 out
    set +u
    [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] && . "$HOME/.sdkman/bin/sdkman-init.sh" >/dev/null 2>&1
    set -u
    command -v mvn >/dev/null 2>&1 || { echo "mvn not on PATH (SDKMAN not initialised?)" >&2; return 1; }
    # -Dit.test (Failsafe). In v1 this class is EXCLUDED from Surefire by pom.xml:541,
    # so `mvn test -Dtest=...` would run nothing and report success.
    # -Dtest=none isolates Failsafe from Surefire. Without it `mvn verify` also runs the FULL
    # unit suite, so ANY pre-existing unrelated unit failure sinks the build and this check
    # reports FAIL for the wrong reason. Observed for real: the SBDEV-2801 regression test
    # (M2) reported FAIL here while passing 4/4 in isolation.
    out=$(mvn verify -Dit.test="$cls" -Dtest=none -Dsurefire.failIfNoSpecifiedTests=false \
              -DfailIfNoTests=false 2>&1)
    if grep -qE "BUILD SUCCESS" <<<"$out" && grep -qE "Tests run: [0-9]+, Failures: 0, Errors: 0" <<<"$out"; then
        return 0
    fi
    printf '%s\n' "$out" | tail -25 >&2
    return 1
}

MIG_DIR="src/main/resources/db/migration"
TEST_DIR="src/test/java/net/aim_ai/wms/service"

resolve_one() { # <dir> <version-prefix>
    local d=$1 v=$2 hits
    hits=$(ls "$d"/${v}__*.sql 2>/dev/null | wc -l)
    [ "$hits" -eq 1 ] || return 1
    ls "$d"/${v}__*.sql
}

MIG="$(resolve_one "$MIG_DIR" 'V1.26.32' || true)"; : "${MIG:=/nonexistent}"
IT="$TEST_DIR/TransactionDetailUlPickIT.java"

echo "SBDEV-2890 (v1) — transaction_detail UL-pick exclusion"
echo "PROJECT_ROOT=$PROJECT_ROOT"
echo "migration=$MIG"
echo

# ── S: structural ───────────────────────────────────────────────────────────
echo "S. Migration structure"
mig_exists()        { [ -f "$1" ]; }
mig_create()        { body 'CREATE OR REPLACE FUNCTION (public\.)?transaction_detail' "$1"; }
mig_no_drop()       { body_not 'DROP FUNCTION' "$1"; }
mig_single_create() { [ "$(body_count "$1" '^CREATE OR REPLACE FUNCTION')" -eq 1 ]; }
# v1 signature — WITHOUT time zone. See header note 2.
# r1 used `transaction_detail\(.*timestamp without time zone.*\)`, which PASSES on a
# THREE-parameter signature missing sku_in — precisely the overload that leaves the broken
# function live and callable, i.e. the exact hazard this check exists to catch. Pin the
# full parameter list verbatim from V1.1.08:3.
mig_signature()     { body 'transaction_detail\(client_number_in character varying, sku_in character varying, startdate_in timestamp without time zone, enddate_in timestamp without time zone\)' "$1"; }
mig_returns()       { body 'RETURNS TABLE\(client_name character varying, client_number character varying' "$1"; }

run S1 "V1.26.32 migration exists (exactly one match)"       mig_exists        "$MIG"
run S2 "CREATE OR REPLACE FUNCTION transaction_detail"       mig_create        "$MIG"
run S3 "no DROP FUNCTION (preserves OID/ownership/ACLs)"     mig_no_drop       "$MIG"
run S4 "exactly one CREATE OR REPLACE in the file"           mig_single_create "$MIG"
run S5 "FULL signature pinned verbatim (no 3-param overload)" mig_signature     "$MIG"
run S6 "RETURNS TABLE column list preserved"                 mig_returns       "$MIG"
echo

# ── H: v1-only hazards ──────────────────────────────────────────────────────
echo "H. v1-only hazards"
# H1 is the inverse of S5 and the single most dangerous v1 failure: copying v2's
# signature creates an overload, leaving the broken function live.
h_not_v2_signature() { body_not 'timestamp with time zone' "$1"; }
# H2: this migration must replace transaction_detail ONLY. V1.1.08 did not redefine
# transaction_summary (V1.1.04:367 is still live) and neither may V1.26.32 —
# redefining it here would silently expand blast radius past the plan's premise.
h_no_summary_redef() { body_not 'CREATE OR REPLACE FUNCTION (public\.)?transaction_summary' "$1"; }
# H3: wrong migration number. V1.1.10 sorts BEFORE the V1.26.x block.
# Broadened: r1 tested ONE exact filename, so any other description — or V1.1.11+ —
# sailed through. Any V1.1.1x migration sorts BEFORE the live V1.26.x tail.
h_no_v1_1_10() { ! ls "$MIG_DIR"/V1.1.1*__*.sql >/dev/null 2>&1; }

run H1 "signature is NOT v2's 'with time zone' (no overload)" h_not_v2_signature "$MIG"
run H2 "does not redefine transaction_summary"                h_no_summary_redef "$MIG"
run H3 "no stray V1.1.10 migration (would sort out-of-order)" h_no_v1_1_10
echo

# ── A: Fix A — the picking predicate ────────────────────────────────────────
echo "A. Fix A — picking guard rescoped per stock-record type"
a_created_arm() {
    body_ml "activitycode = ''PICKING''.{0,120}STOCK_CREATED'' AND coalesce\(sr\.amount, 0\) != 0" "$1"
}
a_transferred_arm() {
    body_ml "STOCK_TRANSFERRED'' AND coalesce\(sr\.amountstock, 0\) != 0" "$1"
}
# Unbounded [[:space:]]* rather than a bounded .{0,N} -- see the v2 script: a bounded
# window >=100 trips ugrep's complexity limit and makes the check unpassable.
a_both_arms_together() {
    body_ml "STOCK_CREATED'' AND coalesce\(sr\.amount, 0\) != 0\)[[:space:]]*OR[[:space:]]*\(sr\.type = ''STOCK_TRANSFERRED'' AND coalesce\(sr\.amountstock, 0\) != 0\)" "$1"
}
a_old_guard_gone() {
    body_not_ml "\(sr\.type = ''STOCK_CREATED'' OR sr\.type = ''STOCK_TRANSFERRED''\) and sr\.amount != 0" "$1"
}
a_transferred_not_on_amount() {
    body_not_ml "STOCK_TRANSFERRED'' AND coalesce\(sr\.amount, 0\) != 0" "$1"
}

run A1 "STOCK_CREATED arm gated on sr.amount"                  a_created_arm               "$MIG"
run A2 "STOCK_TRANSFERRED arm gated on sr.amountstock"         a_transferred_arm           "$MIG"
run A3 "both arms OR'd inside one PICKING predicate"           a_both_arms_together        "$MIG"
run A4 "old whole-group 'and sr.amount != 0' guard REMOVED"    a_old_guard_gone            "$MIG"
run A5 "TRANSFERRED arm not gated on sr.amount (bug restated)" a_transferred_not_on_amount "$MIG"
echo

# ── V: the value CASE must survive untouched ────────────────────────────────
echo "V. Value CASE preserved (was correct, merely unreachable)"
v_created_value()     { body_ml "PICKING'' AND sr\.type = ''STOCK_CREATED''[[:space:]]*THEN sr\.amount" "$1"; }
v_transferred_value() { body_ml "PICKING'' AND sr\.type = ''STOCK_TRANSFERRED''[[:space:]]*THEN sr\.amountstock" "$1"; }
run V1 "PICKING/STOCK_CREATED still valued from sr.amount"       v_created_value     "$MIG"
run V2 "PICKING/STOCK_TRANSFERRED still valued from amountstock" v_transferred_value "$MIG"
echo

# ── C: no inline comment inside the EXECUTE string ──────────────────────────
echo "C. Changed predicate carries no inline comment"
c_no_inline_comment() {
    [ -f "$1" ] || return 1
    ! sed '/^[[:space:]]*--/d' "$1" \
      | grep -E "coalesce\(sr\.(amount|amountstock), 0\) != 0" \
      | grep -q -- '--'
}
run C1 "no inline -- on the rescoped predicate lines" c_no_inline_comment "$MIG"
echo

# ── T: the regression test — and the INVERTED suffix trap ───────────────────
# NOTE: T-checks match JAVA files RAW -- see the v2 script for why comment-stripping
# is wrong here (SQL `--` stripper vs Java `//`, and `--` is Java's decrement operator).
echo "T. Regression test (v1 requires the ...IT.java suffix)"
t_exists()              { [ -f "$1" ]; }
t_wrong_suffix_absent() { [ ! -f "$TEST_DIR/TransactionDetailUlPickIntegrationTest.java" ] \
                       && [ ! -f "src/test/java/net/aim_ai/wms/integration/TransactionDetailUlPickIntegrationTest.java" ]; }
t_harness_pg()          { file_contains 'PostgreSQLContainer' "$1"; }
t_flyway_loc()          { file_contains 'classpath:db/migration' "$1"; }
t_ac5_recon()           { file_contains 'transaction_summary' "$1" && grep -qE 'AC-5' "$1"; }
# r1 matched any INSERT column list mentioning both names, so it could not verify the
# property it is named for. Require the fixture to actually TIE the two values — either
# by assigning one from the other, or by a named constant used for both.
t_created_eq_modified() {
    file_contains_ml '(created[^;]{0,120}modified|modified[^;]{0,120}created|SAME_TS|createdEqualsModified)' "$1"
}
# AC-1 must seed amount=0 AND a non-zero amountstock -- the row that is invisible today.
# r1's `STOCK_TRANSFERRED.{0,400}amountstock` matched any mention of both.
t_ac1_ul_pick() {
    body_ml "STOCK_TRANSFERRED" "$1" && body_ml "PICKING" "$1" && body_ml "amountstock" "$1" \
      && body_ml "(depleted_picked|DEPLETED_PICKED)" "$1"
}
# r1's `STOCK_CREATED.{0,400}(0|ZERO)` matched any `0` digit within 400 chars -- near
# unfalsifiable. Require the AC-2 identifier itself, which the plan mandates in a
# @DisplayName or comment, plus the STOCK_CREATED literal.
t_ac2_placeholder() { file_contains "STOCK_CREATED" "$1" && grep -qE 'AC-2' "$1"; }
# v1 CLAUDE.md: Mockito 3.3.3 — mockStatic() is unavailable. A test reaching for it
# will not compile; catch it here rather than in CI.
t_no_mockstatic()       { file_not_contains 'mockStatic|MockedStatic' "$1"; }

run T1 "TransactionDetailUlPickIT.java exists"                t_exists "$IT"
run T2 "no ...IntegrationTest.java twin (never runs in v1)"   t_wrong_suffix_absent
run T3 "uses raw Testcontainers PostgreSQLContainer"          t_harness_pg   "$IT"
run T4 "Flyway runs classpath:db/migration"                   t_flyway_loc   "$IT"
run T5 "AC-5 reconciles against transaction_summary"          t_ac5_recon    "$IT"
run T6 "fixture ties created to modified (AC-5 stability)"    t_created_eq_modified "$IT"
run T7 "AC-1 seeds a STOCK_TRANSFERRED/amountstock row"       t_ac1_ul_pick  "$IT"
run T8 "AC-2 seeds a zero-amount STOCK_CREATED row"           t_ac2_placeholder "$IT"
run T9 "no mockStatic (unavailable on Mockito 3.3.3)"         t_no_mockstatic "$IT"

# AC-9 / AC-10 — see the v2 script for the full rationale. Anchor is TICKET-SCOPED:
# a bare `AC-9` is not unique (other suites in these repos number criteria the same
# way), so only files naming SBDEV-2890 count.
ac_in_ticket_tests() { # <ac-id>
    local ac=$1 f
    for f in $(grep -rl 'SBDEV-2890' src/test/java 2>/dev/null); do
        grep -qE "\b${ac}\b" "$f" && return 0
    done
    return 1
}
t_ac9_structural()  { ac_in_ticket_tests 'AC-9';  }
t_ac10_invariant()  { ac_in_ticket_tests 'AC-10'; }
run T10 "AC-9 structural allow-list/value-CASE assertion present" t_ac9_structural
run T11 "AC-10 full-move write-path invariant asserted"           t_ac10_invariant
echo

# ── M: the suite ────────────────────────────────────────────────────────────
echo "M. Maven (Failsafe)"
if [ -f "$IT" ]; then
    run M1 "mvn verify -Dit.test=TransactionDetailUlPickIT" mvn_verify_passes TransactionDetailUlPickIT
else
    printf "  FAIL  %-8s  %s\n" "M1" "test absent — behavioural gate cannot run (not a SKIP)"; FAIL=$((FAIL+1))
fi
echo
# NOTE: there is deliberately no AC-6 regression row here. v1 has NO existing
# transaction_detail / transaction_summary test to re-run — that absence is itself a
# finding recorded in plan §8.4, not something to paper over with a fake check.

echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ] && [ "$SKIP" -eq 0 ] || exit 1
exit 0
