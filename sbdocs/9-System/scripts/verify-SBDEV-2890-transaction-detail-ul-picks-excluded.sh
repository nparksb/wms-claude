#!/usr/bin/env bash
# verify-SBDEV-2890-transaction-detail-ul-picks-excluded.sh   [revision 1]
#
# Machine-checkable acceptance for SBDEV-2890 (v2) — transaction_detail() excludes
# every full-move unit-load pick because the picking WHERE arm gates BOTH stock-record
# types on sr.amount, while UL picks are written with amount=0 and the quantity in
# amountstock.
#
# Plan: sbdocs/1-Projects/wms2/plan/SBDEV-2890-transaction-detail-ul-picks-excluded.md
#
#   PROJECT_ROOT=/Users/np1076/dev/spk/owl/v2/wms2-api \
#     bash sbdocs/9-System/scripts/verify-SBDEV-2890-transaction-detail-ul-picks-excluded.sh
#
# Exit 0 ONLY on "N pass, 0 fail, 0 skip". Paste that line in the end-of-task report.
#
# ── Idiom inherited from verify-SBDEV-2777 (r3). Do not "simplify" these back out ──
#   * SKIP counts as FAIL. A skipped behavioural gate that still exits 0 is how r1 of
#     the 2777 script certified an unfinished fix.
#   * Migrations resolve by VERSION PREFIX, never by description suffix — a correct fix
#     under a slightly different filename must not make every negative check pass
#     vacuously.
#   * Every negative check is gated on the file existing. `! grep` against a missing
#     file exits 2, which inverts to TRUE. Ungated negatives are the classic false-PASS.
#   * count_matches has no `|| echo 0` — `grep -c` prints 0 AND exits 1 on no match, so
#     the fallback appends a second 0 and the arithmetic throws.
#   * mvn runs without -q (that hides BUILD SUCCESS and "Tests run:") and disarms `set -u`
#     around sdkman-init.sh, which references unbound vars and would kill the whole shell
#     before "Result:" ever prints.
#
# ── What this proves, and what it does NOT ──────────────────────────────────
# CODE SHAPE only. Acceptance ALSO requires:
#   - mvn verify green, incl. AC-1..AC-10 (plan §8.3/§8.4)
#   - the plan's §8.5 manual plan run against UAT (scenarios 1-3 minimum)
#   - the plan's §11 queries run and recorded (this plan is db_verified: false)
# A green run here with those unrun is NOT acceptance.
#
# ── Run it BEFORE the fix ───────────────────────────────────────────────────
# Against the pre-fix tree this MUST report many FAILs (the migration does not exist
# yet). If it passes before the fix, the checks are wrong — fix them, not the code.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/Users/np1076/dev/spk/owl/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0

# Diagnostics are captured, not discarded, and surfaced ONLY on failure. r1 used
# `>/dev/null 2>&1`, which threw away the `tail -25 >&2` that mvn_verify_passes exists to
# emit — a failing M1 printed one word with zero context.
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

# NEGATIVE checks MUST assert the file exists first. `! grep` against a missing file
# exits 2, which inverts to TRUE — so an ungated negative reports PASS on a tree where
# the fix was never written. Caught in r1 of this script: the pre-fix baseline scored
# S3/A4/A5/H6 as PASS against a nonexistent V2.2.12.
file_not_contains()    { [ -f "$2" ] && ! grep -qE "$1" "$2"; }
file_not_contains_ml() { [ -f "$2" ] && ! tr '\n' ' ' < "$2" | grep -qE "$1"; }

# ── COMMENT-BLIND MATCHING (r2) — every structural assertion must use these ─────
# r1 matched against the RAW file and was wrong in BOTH directions:
#   * FALSE FAIL on a correct fix. §5.3 Hazard 2 tells the implementer to describe the
#     change in the file header. That header quotes the OLD predicate, so `a_old_guard_gone`
#     saw it and failed a perfectly good migration.
#   * FALSE PASS on a broken fix — the dangerous direction. V2.2.08's own header at :27-30
#     literally contains, as comment text:
#         --   86   ~ coalesce(bp.amount, 0)   AS shipped
#         --   87   ~ -coalesce(bp.amount, 0)  AS net_change
#         --   192  ~ ELSE 0 END, 0) AS received
#         --   223  ~ ELSE 0 END, 0) AS returned
#     §7.2 Step 3 says to copy V2.2.08, so that header comes along. H1-H4 therefore passed
#     with NO function body at all — meaning the machine gate on Hazard 1, whose failure
#     mode is a production HTTP 500, certified green on a V2.2.00-derived body.
# Only H5 (coalesce(sh.historical_stock,0): 4 in V2.2.08, 0 in V2.2.00) ever discriminated.
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
    # NOTE: -Dit.test (Failsafe), NOT -Dtest (Surefire). In v2 this class is EXCLUDED
    # from Surefire by pom.xml:450-451 — `mvn test -Dtest=...` would run nothing and
    # report success.
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
TEST_DIR="src/test/java/net/aim_ai/wms/integration"

resolve_one() { # <dir> <version-prefix>
    local d=$1 v=$2 hits
    hits=$(ls "$d"/${v}__*.sql 2>/dev/null | wc -l)
    [ "$hits" -eq 1 ] || return 1          # 0 = missing, >1 = ambiguous duplicate
    ls "$d"/${v}__*.sql
}

MIG="$(resolve_one "$MIG_DIR" 'V2.2.12' || true)";  : "${MIG:=/nonexistent}"
ANC="$(resolve_one "$MIG_DIR" 'V2.2.08' || true)";  : "${ANC:=/nonexistent}"
IT="$TEST_DIR/TransactionDetailUlPickIntegrationTest.java"

echo "SBDEV-2890 (v2) — transaction_detail UL-pick exclusion"
echo "PROJECT_ROOT=$PROJECT_ROOT"
echo "migration=$MIG"
echo

# ── S: structural ───────────────────────────────────────────────────────────
echo "S. Migration structure"
mig_exists()        { [ -f "$1" ]; }
mig_create()        { body 'CREATE OR REPLACE FUNCTION public\.transaction_detail' "$1"; }
mig_no_drop()       { body_not 'DROP FUNCTION' "$1"; }
mig_single_create() { [ "$(body_count "$1" '^CREATE OR REPLACE FUNCTION')" -eq 1 ]; }
# Signature must be byte-identical to V2.2.08's or CREATE OR REPLACE makes an OVERLOAD
# instead of replacing, leaving the broken function live (plan §5.2.4, AC-7).
mig_signature()     { body 'transaction_detail\(client_number_in character varying, sku_in character varying, startdate_in timestamp with time zone, enddate_in timestamp with time zone\)' "$1"; }
mig_returns()       { body 'RETURNS TABLE\(client_name character varying, client_number character varying, sku character varying' "$1"; }

run S1 "V2.2.12 migration exists (exactly one match)"      mig_exists        "$MIG"
run S2 "CREATE OR REPLACE FUNCTION transaction_detail"     mig_create        "$MIG"
run S3 "no DROP FUNCTION (preserves OID/ownership/ACLs)"   mig_no_drop       "$MIG"
run S4 "exactly one CREATE OR REPLACE in the file"         mig_single_create "$MIG"
run S5 "signature byte-identical to V2.2.08 (no overload)" mig_signature     "$MIG"
run S6 "RETURNS TABLE column list preserved"               mig_returns       "$MIG"
echo

# ── A: Fix A — the picking predicate ────────────────────────────────────────
# Positive: each type gated on the column that actually carries its quantity.
# Anchored to the PICKING arm so a correct-looking coalesce elsewhere cannot satisfy it.
echo "A. Fix A — picking guard rescoped per stock-record type"
a_created_arm() {
    body_ml "activitycode = ''PICKING''.{0,120}STOCK_CREATED'' AND coalesce\(sr\.amount, 0\) != 0" "$1"
}
a_transferred_arm() {
    body_ml "STOCK_TRANSFERRED'' AND coalesce\(sr\.amountstock, 0\) != 0" "$1"
}
# The two arms must sit in the SAME predicate, OR'd together — not split across the file.
# Unbounded [[:space:]]* rather than a bounded .{0,N}: after tr '\n' ' ' everything
# between the arms is whitespace, so a bounded window buys nothing and costs a ugrep
# "exceeds complexity limits" error at N>=100 -- which exits 2 and is indistinguishable
# from a failed assertion, i.e. a check that can NEVER pass on a correct fix.
# The trailing \) also anchors the end of the TRANSFERRED arm, which .{0,20} never did.
a_both_arms_together() {
    body_ml "STOCK_CREATED'' AND coalesce\(sr\.amount, 0\) != 0\)[[:space:]]*OR[[:space:]]*\(sr\.type = ''STOCK_TRANSFERRED'' AND coalesce\(sr\.amountstock, 0\) != 0\)" "$1"
}
# NEGATIVE: the old whole-group guard must be gone. This is the check that fails
# before the fix and is the single most important assertion in this script.
a_old_guard_gone() {
    body_not_ml "\(sr\.type = ''STOCK_CREATED'' OR sr\.type = ''STOCK_TRANSFERRED''\) and sr\.amount != 0" "$1"
}
# The transferred arm must NOT be gated on sr.amount — that is the bug restated.
a_transferred_not_on_amount() {
    body_not_ml "STOCK_TRANSFERRED'' AND coalesce\(sr\.amount, 0\) != 0" "$1"
}

run A1 "STOCK_CREATED arm gated on sr.amount"              a_created_arm             "$MIG"
run A2 "STOCK_TRANSFERRED arm gated on sr.amountstock"     a_transferred_arm         "$MIG"
run A3 "both arms OR'd inside one PICKING predicate"       a_both_arms_together      "$MIG"
run A4 "old whole-group 'and sr.amount != 0' guard REMOVED" a_old_guard_gone         "$MIG"
run A5 "TRANSFERRED arm not gated on sr.amount (bug restated)" a_transferred_not_on_amount "$MIG"
echo

# ── V: the value CASE must survive untouched ────────────────────────────────
echo "V. Value CASE preserved (was correct, merely unreachable)"
v_created_value()     { body_ml "PICKING'' AND sr\.type = ''STOCK_CREATED''[[:space:]]*THEN sr\.amount" "$1"; }
v_transferred_value() { body_ml "PICKING'' AND sr\.type = ''STOCK_TRANSFERRED''[[:space:]]*THEN sr\.amountstock" "$1"; }
run V1 "PICKING/STOCK_CREATED still valued from sr.amount"      v_created_value     "$MIG"
run V2 "PICKING/STOCK_TRANSFERRED still valued from amountstock" v_transferred_value "$MIG"
echo

# ── H1: Hazard 1 — copied from V2.2.08, NOT V2.2.00 ─────────────────────────
# If V2.2.12 was derived from V2.2.00 it silently reverts SBDEV-2801's six NULL
# coalesces and reintroduces a production HTTP 500. These six assertions are the
# machine-checkable form of plan §5.3 Hazard 1.
echo "H. Hazard 1 — SBDEV-2801 NULL-hardening carried forward"
h_shipped()    { body 'coalesce\(bp\.amount, 0\)[[:space:]]+AS shipped' "$1"; }
# grep needs `--` here: the pattern starts with '-'. Cannot route through file_contains,
# which would consume the `--` as its $1.
h_netchange()  { [ -f "$1" ] && strip_comments "$1" | grep -qE -- '-coalesce\(bp\.amount, 0\)[[:space:]]+AS net_change'; }
# `[[:space:]]+` not a literal space: the real V2.2.08 text is
# `ELSE 0 END, 0)          AS returned` with column-aligned padding. A single-space regex
# false-FAILED a correct migration — caught by running this script against a constructed
# correct fix rather than only against the pre-fix tree.
h_received()   { body_ml 'ELSE 0 END, 0\)[[:space:]]+AS received' "$1"; }
h_returned()   { body_ml 'ELSE 0 END, 0\)[[:space:]]+AS returned' "$1"; }
# BEGINNING and ENDING branches both coalesce historical_stock -> expect >= 2.
h_total_pair() { [ "$(body_count "$1" 'coalesce\(sh\.historical_stock, 0\)')" -ge 2 ]; }

run H1 "shipped keeps coalesce(bp.amount, 0)"          h_shipped    "$MIG"
run H2 "net_change keeps -coalesce(bp.amount, 0)"      h_netchange  "$MIG"
run H3 "received keeps two-arg coalesce"               h_received   "$MIG"
run H4 "returned keeps two-arg coalesce"               h_returned   "$MIG"
run H5 "historical_stock coalesced in BOTH branches"   h_total_pair "$MIG"
echo

# ── H2: Hazard 2 — no inline comment inside the EXECUTE string ──────────────
# V2.2.08:33-35 warns: a comment inside the quoted body is STORED in the function
# and changes pg_get_functiondef output, breaking any recurrence gate that diffs it.
echo "H. Hazard 2 — changed predicate carries no inline comment"
h_no_inline_comment() {
    # Catch an inline `--` on the CHANGED PREDICATE LINES, which would be stored in the
    # function body and change pg_get_functiondef output (V2.2.08:33-35).
    # Two-stage, and the order matters: first DROP whole-line header comments (the header
    # legitimately describes the change and legitimately contains `--`), then look for a
    # surviving `--` on a line that also carries the new coalesce arms. r1 skipped the drop
    # and so failed a correctly-written migration whose header documented the change.
    [ -f "$1" ] || return 1
    ! sed '/^[[:space:]]*--/d' "$1" \
      | grep -E "coalesce\(sr\.(amount|amountstock), 0\) != 0" \
      | grep -q -- '--'
}
run H6 "no inline -- on the rescoped predicate lines"  h_no_inline_comment "$MIG"
echo

# ── T: the regression test — and the suffix trap ────────────────────────────
# v2 Surefire EXCLUDES **/*IntegrationTest.java (pom.xml:450-451) and Failsafe
# INCLUDES it (pom.xml:567-568). A file named ...IT.java in THIS repo never runs.
# NOTE: T-checks match JAVA files RAW. Do NOT route them through strip_comments --
# that is an SQL `--` stripper: it does not touch Java `//`, and `--` is Java's
# decrement operator, so `for (int i = n; i-- > 0;)` would be truncated and could
# false-FAIL a correct test. The plan also MANDATES the AC ids live in a @DisplayName
# or comment, so stripping comments would delete the very anchor being matched.
echo "T. Regression test"
t_exists()      { [ -f "$1" ]; }
# Check BOTH plausible locations — a misnamed file dropped in service/ rather than
# integration/ is just as invisible to Failsafe as one in the expected directory.
t_wrong_suffix_absent() {
    [ ! -f "$TEST_DIR/TransactionDetailUlPickIT.java" ] \
 && [ ! -f "src/test/java/net/aim_ai/wms/service/TransactionDetailUlPickIT.java" ]
}
t_harness_pg()  { file_contains 'PostgreSQLContainer' "$1"; }
t_harness_pg16(){ file_contains 'postgres:16' "$1"; }
t_flyway_loc()  { file_contains 'classpath:db/migration' "$1"; }
# AC-5 — the reconciliation assertion. This is the criterion that would have caught
# the whole bug class, and it exists nowhere in either repo today.
# Must be an ASSERTION, not a mention: the repo's only existing hit is a comment.
t_ac5_recon()   { file_contains 'transaction_summary' "$1" && grep -qE 'AC-5' "$1"; }
# Fixture must seed created == modified or AC-5 false-fails on the documented
# sr.created / sr.modified windowing divergence (plan §8.2, §10.4).
# r1 matched any INSERT column list mentioning both names, so it could not verify the
# property it is named for. Require the fixture to actually TIE the two values — either
# by assigning one from the other, or by a named constant used for both.
t_created_eq_modified() {
    file_contains_ml '(created[^;]{0,120}modified|modified[^;]{0,120}created|SAME_TS|createdEqualsModified)' "$1"
}
# AC-1: the row that is invisible today.
# AC-1 must seed amount=0 AND a non-zero amountstock -- the row that is invisible today.
# r1's `STOCK_TRANSFERRED.{0,400}amountstock` matched any mention of both.
t_ac1_ul_pick() {
    body_ml "STOCK_TRANSFERRED" "$1" && body_ml "PICKING" "$1" && body_ml "amountstock" "$1" \
      && body_ml "(depleted_picked|DEPLETED_PICKED)" "$1"
}
# AC-2: the placeholder row must STILL be suppressed.
# r1's `STOCK_CREATED.{0,400}(0|ZERO)` matched any `0` digit within 400 chars -- near
# unfalsifiable. Require the AC-2 identifier itself, which the plan mandates in a
# @DisplayName or comment, plus the STOCK_CREATED literal.
t_ac2_placeholder() { file_contains "STOCK_CREATED" "$1" && grep -qE 'AC-2' "$1"; }

run T1 "TransactionDetailUlPickIntegrationTest.java exists"   t_exists "$IT"
run T2 "no ...IT.java twin (would never run in v2)"           t_wrong_suffix_absent
run T3 "uses raw Testcontainers PostgreSQLContainer"          t_harness_pg   "$IT"
run T4 "pins postgres:16 (matches production tenants)"        t_harness_pg16 "$IT"
run T5 "Flyway runs classpath:db/migration"                   t_flyway_loc   "$IT"
run T6 "AC-5 reconciles against transaction_summary"          t_ac5_recon    "$IT"
run T7 "fixture ties created to modified (AC-5 stability)"    t_created_eq_modified "$IT"
run T8 "AC-1 seeds a STOCK_TRANSFERRED/amountstock row"       t_ac1_ul_pick  "$IT"
run T9 "AC-2 seeds a zero-amount STOCK_CREATED row"           t_ac2_placeholder "$IT"

# AC-9 — the structural criterion that closes the BUG CLASS rather than this instance.
# Asserts every activitycode/type pair in a value CASE is admitted by the WHERE
# allow-list. Would have caught both the picking bug and the `received` sibling.
# It may live in its own test class, so this searches repo-wide — but it MUST be
# anchored on the literal AC id. r1 of these two checks matched `STOCK_REMOVED` and
# `transferStockToUnitLoad` repo-wide, which existing unrelated tests already contain,
# so both scored PASS against a tree where neither AC had been written. Requiring the
# AC identifier in a @DisplayName or comment is the cheapest unambiguous anchor, and
# the plan §8.3 mandates it.
# r1 anchored on a bare `AC-9`, which 11 UNRELATED test files in this repo already use
# (the schedulejob metrics suites number their criteria the same way). AC ids are only
# unique WITHIN a ticket, so the anchor must be ticket-scoped: look only inside files
# that name SBDEV-2890.
ac_in_ticket_tests() { # <ac-id>
    local ac=$1 f
    for f in $(grep -rl 'SBDEV-2890' src/test/java 2>/dev/null); do
        grep -qE "\b${ac}\b" "$f" && return 0
    done
    return 1
}
t_ac9_structural() { ac_in_ticket_tests 'AC-9'; }
# AC-10 — the write-path invariant AC-1 silently depends on: the full-move branch is
# taken only when amount == sourceStockunit.getAmount(). All SQL fixtures seed via raw
# JDBC, so without this a change to StockunitBusinessService:336 over-reports picked
# quantity with every test still green.
t_ac10_invariant() { ac_in_ticket_tests 'AC-10'; }
run T10 "AC-9 structural allow-list/value-CASE assertion present" t_ac9_structural
run T11 "AC-10 full-move write-path invariant asserted"           t_ac10_invariant
echo

# ── M: the suite ────────────────────────────────────────────────────────────
# Gated on the test existing so a missing test FAILs at T1 rather than producing a
# confusing maven error here. SKIP is not used — an unrun behavioural gate is a FAIL.
echo "M. Maven (Failsafe)"
if [ -f "$IT" ]; then
    run M1 "mvn verify -Dit.test=TransactionDetailUlPickIntegrationTest" \
        mvn_verify_passes TransactionDetailUlPickIntegrationTest
    run M2 "mvn verify -Dit.test=TransactionDetailNullAmountIntegrationTest (AC-6)" \
        mvn_verify_passes TransactionDetailNullAmountIntegrationTest
else
    printf "  FAIL  %-8s  %s\n" "M1" "test absent — behavioural gate cannot run (not a SKIP)"; FAIL=$((FAIL+1))
    printf "  FAIL  %-8s  %s\n" "M2" "test absent — regression gate cannot run (not a SKIP)";  FAIL=$((FAIL+1))
fi
echo

echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ] && [ "$SKIP" -eq 0 ] || exit 1
exit 0
