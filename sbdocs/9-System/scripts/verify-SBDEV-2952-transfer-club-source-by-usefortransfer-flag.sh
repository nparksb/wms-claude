#!/usr/bin/env bash
# verify-SBDEV-2952-transfer-club-source-by-usefortransfer-flag.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2952-transfer-club-source-by-usefortransfer-flag.md
#
# What this proves, and what it does NOT
# --------------------------------------
# PROVES: the code SHAPE landed — the new predicate is in the right @Query, the
#         load-bearing disjuncts survived, both callers reach ONE shared method,
#         and every trace of the old name-matching query is gone.
# DOES NOT PROVE: that the SQL is valid or returns the right rows. Per plan §7.4
#         the native query has ZERO automated coverage (UnitloadRepositoryTest is
#         @Disabled; every other test mocks the repository). Predicate correctness
#         rests on the §2.4 DB differential and the §7.3 manual rows M1/M4/M5/M7.
#         A green run here is necessary, not sufficient.
#
# Usage:
#   PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
#     bash sbdocs/9-System/scripts/verify-SBDEV-2952-transfer-club-source-by-usefortransfer-flag.sh
#
# When grading an implementation worktree, point PROJECT_ROOT at the worktree (or
# a symlink shadow root) — otherwise this grades the main checkout, not the work.
#
# Exit code 0 only when every check passes.
#
# NEGATIVE-TEST THIS SCRIPT BEFORE TRUSTING IT (plan §9.1): run it against the
# pre-change tree. It MUST report failures. A "N pass, 0 fail" on unchanged code
# means the script asserts nothing.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

REPO_FILE=src/main/java/net/aim_ai/wms/repo/jpa/UnitloadRepository.java
XFER_FILE=src/main/java/net/aim_ai/wms/service/TransferOrderService.java
CLUB_FILE=src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java
# Written by the TDD gate (2026-08-14). NOTE: the plan §7.2 originally proposed the name
# UnitloadRepositoryUsersAreaConstantTest; the gate folded that assertion into a broader
# reflection-based contract test instead. This path MUST match the file that actually exists —
# a row naming a non-existent file records bash's failure as an ordinary FAIL and is
# indistinguishable from unimplemented work.
CONST_TEST=src/test/java/net/aim_ai/wms/unit/repo/UnitloadRepositoryTransferableAreasContractTest.java

NEW_METHOD='getBatchLocationsByItemIdAndTransferableAreas'
OLD_METHOD='getBatchLocationsByItemIdAndNamedLocations'

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

# --- assertion helpers -------------------------------------------------------
# EVERY helper guards on file existence FIRST. The stock template's
# file_not_contains fails OPEN on a missing file (`! grep` on ENOENT → exit 0),
# which false-greens every negative assertion. Do not remove these guards.

file_exists() { [ -f "$1" ]; }

file_contains()     { [ -f "$2" ] || return 1; grep -qE "$1" "$2"; }
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }

# Extract the annotated method block for $2 in file $1 — from its @RestResource
# line through the terminating semicolon of its signature — then match $3 inside
# it. Scoping to the block is what stops a check passing on a DIFFERENT query
# elsewhere in the same repository interface.
method_block_contains() {
    local file=$1 method=$2 pattern=$3
    [ -f "$file" ] || return 1
    # The env assignments MUST precede `perl`. Passing them after the -e script
    # makes perl treat them as input FILENAMES, leaving $ENV{...} undef — which
    # collapses the block regex to "match anything" and false-greens every check.
    # This exact bug survived the first draft and was caught only by the
    # pre-change negative test. Do not reorder.
    MB_METHOD="$method" MB_PATTERN="$pattern" perl -0777 -ne '
        my $m = $ENV{MB_METHOD};
        my $p = $ENV{MB_PATTERN};
        die "MB_METHOD/MB_PATTERN not set" unless defined $m && length $m
                                              && defined $p && length $p;
        if (/\@RestResource\([^)]*\Q$m\E.*?;/s) {
            my $block = $&;
            exit($block =~ /$p/s ? 0 : 1);
        }
        exit 1;
    ' "$file" 2>/dev/null
}

# Count call sites of a bare method name across src/main (excludes the interface
# declaration itself by requiring a "." before the name).
main_callsite_count_is() {
    local method=$1 expected=$2 count
    count=$(grep -rE "\.${method}\s*\(" src/main/java --include=*.java 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" = "$expected" ]
}

# Absent from src/main (production code) entirely.
absent_from_main() {
    local pattern=$1
    [ -d src/main/java ] || return 1
    ! grep -rqE "$pattern" src/main/java --include=*.java 2>/dev/null
}

# No remaining CALL of the old method anywhere in src/test.
#
# Deliberately matches a dot-call (`.method(`) rather than the bare name: the gate's own
# contract test must NAME the old method as a string literal in order to assert its
# absence (UnitloadRepositoryTransferableAreasContractTest.OLD_METHOD). A bare-name grep
# over src/ would therefore be PERMANENTLY RED no matter how correct the implementation —
# indistinguishable from unfinished work. A dot-call grep still catches every unconverted
# Mockito stub/verify, which is what this row is actually for.
#
# (PR-review revision, 2026-08-14: the two AC5 service tests used to carry a
# `.doesNotContain("<old name>")` assertion as well. Those were vacuous — a method absent
# from the interface can never appear in a Mockito invocation record — and were dropped in
# favour of a value-pinned `verify(...)`. Only the contract test names the old method now.)
no_test_calls_old_method() {
    [ -d src/test/java ] || return 1
    ! grep -rqE "\.${OLD_METHOD}\s*\(" src/test/java --include=*.java 2>/dev/null
}

# Review addendum (2026-08-14): LocationService.getClearing() is an uncached findByName
# (LocationService:117), so resolving it inside the per-SKU loop issued one extra query
# per SKU on a screen that routinely lists thousands. Both callers now resolve it lazily,
# once per invocation.
#
# Graded as a PAIR, because either half alone false-greens: the holder variable can exist
# while the call still passes locationService.getClearing() directly, and the call can pass
# a variable that was never hoisted. The call's argument list is captured with a tempered
# greedy gap so the match cannot run past `);` into an unrelated construct.
clearing_hoisted_in() {
    local file=$1
    [ -f "$file" ] || return 1
    grep -qE 'Long[[:space:]]+clearingLocationId[[:space:]]*=[[:space:]]*null[[:space:]]*;' "$file" || return 1
    CH_METHOD="$NEW_METHOD" perl -0777 -ne '
        my $m = $ENV{CH_METHOD};
        die "CH_METHOD not set" unless defined $m && length $m;
        unless (/\.\Q$m\E\s*\((?:(?!\)\s*;).)*\)\s*;/s) { exit 1 }
        my $call = $&;
        exit($call =~ /getClearing/ ? 1 : 0);
    ' "$file" 2>/dev/null
}

mvn_test_passes() {
    local test_class=$1
    mvn test -Dtest="$test_class" -DfailIfNoTests=false -q 2>&1 \
        | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0"
}

# === §3.1 — the repository query ============================================

check_R1_new_method_declared() {
    file_contains "List<Unitload>\s+${NEW_METHOD}\s*\(" "$REPO_FILE"
}

# Exactly two @Param on the new method — proves the 3rd arg was dropped (D2),
# not merely renamed.
check_R2_two_params_only() {
    [ -f "$REPO_FILE" ] || return 1
    local sig
    sig=$(perl -0777 -ne '
        if (/List<Unitload>\s+getBatchLocationsByItemIdAndTransferableAreas\s*\((.*?)\);/s) { print $1; }
    ' "$REPO_FILE" 2>/dev/null)
    [ -n "$sig" ] || return 1
    local n
    n=$(printf '%s' "$sig" | grep -o '@Param' | wc -l | tr -d ' ')
    [ "$n" = "2" ] && ! printf '%s' "$sig" | grep -q 'locationNameList'
}

check_R3_flag_predicate_present() {
    method_block_contains "$REPO_FILE" "$NEW_METHOD" 'area\.usefortransfer\s*=\s*true'
}

check_R4_users_disjunct_present() {
    method_block_contains "$REPO_FILE" "$NEW_METHOD" "area\\.name\\s*=\\s*'users'"
}

# §2.4 step 3 — LEFT JOIN preserved. INNER JOIN would silently drop staginglane
# and Clearing rows whose location has no area.
check_R5_left_join_preserved() {
    method_block_contains "$REPO_FILE" "$NEW_METHOD" 'LEFT\s+JOIN\s+location_area'
}

# §2.4 step 4 — THE trap. All 20 staging lanes on wineco sit in Outbound, which
# is neither usefortransfer nor users, so this disjunct carries them alone.
check_R6_staginglane_disjunct_preserved() {
    method_block_contains "$REPO_FILE" "$NEW_METHOD" 'lo\.staginglane\s*=\s*true'
}

check_R7_clearing_disjunct_preserved() {
    method_block_contains "$REPO_FILE" "$NEW_METHOD" 'lo\.id\s*=\s*:clearingLocationId'
}

# === §3.2 — both callers on the ONE shared method ===========================

check_C1_transfer_calls_new() { file_contains "\.${NEW_METHOD}\s*\(" "$XFER_FILE"; }
check_C2_club_calls_new()     { file_contains "\.${NEW_METHOD}\s*\(" "$CLUB_FILE"; }

# AC5 as a COUNT, not two independent greps: exactly two production call sites.
# A third caller, or a caller that quietly kept the old method, fails here.
check_C3_exactly_two_callsites() { main_callsite_count_is "$NEW_METHOD" 2; }

check_H1_transfer_clearing_hoisted() { clearing_hoisted_in "$XFER_FILE"; }
check_H2_club_clearing_hoisted()     { clearing_hoisted_in "$CLUB_FILE"; }

# === Negative checks — the old construct is fully gone =======================

check_N1_old_method_gone_from_main()  { absent_from_main "$OLD_METHOD"; }
check_N1b_no_test_stubs_old_method()  { no_test_calls_old_method; }
check_N2_old_predicate_gone()         { file_not_contains 'area\.name\s+IN\s*\(:locationNameList\)' "$REPO_FILE"; }
check_N3_xfer_arraylist_gone()        { file_not_contains 'Arrays\.asList\(\s*AREA_INBOUND_NAME' "$XFER_FILE"; }
check_N4_club_arraylist_gone()        { file_not_contains 'Arrays\.asList\(\s*AREA_INBOUND_NAME' "$CLUB_FILE"; }

# NOTE (plan §3.3): there is deliberately NO check asserting deletion of the five
# now-unreferenced AREA_*_NAME constants. They are retained on purpose.

# === §3.4 / §7.2 — the constant-coupling guard ==============================

check_T1_const_test_exists()   { file_exists "$CONST_TEST"; }
check_T2_const_test_asserts()  { file_contains 'AREA_USERS_NAME' "$CONST_TEST"; }

# === Wire into the runner ===================================================

echo
echo "verify-SBDEV-2952 — Transfer/Club source by usefortransfer flag"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo
echo "  §3.1 repository query"
run R1  "new method declared"                   check_R1_new_method_declared
run R2  "exactly 2 @Param, locationNameList gone" check_R2_two_params_only
run R3  "area.usefortransfer = true present"    check_R3_flag_predicate_present
run R4  "area.name = 'users' disjunct present"  check_R4_users_disjunct_present
run R5  "LEFT JOIN location_area preserved"     check_R5_left_join_preserved
run R6  "staginglane disjunct preserved"        check_R6_staginglane_disjunct_preserved
run R7  "clearing disjunct preserved"           check_R7_clearing_disjunct_preserved
echo
echo "  §3.2 shared method, both callers"
run C1  "TransferOrderService calls new method" check_C1_transfer_calls_new
run C2  "CustomerorderBatchService calls new"   check_C2_club_calls_new
run C3  "exactly 2 prod call sites (AC5)"       check_C3_exactly_two_callsites
echo
echo "  PR-review addendum — Clearing resolved once per call, not per SKU"
run H1  "Transfer hoists getClearing() out of loop" check_H1_transfer_clearing_hoisted
run H2  "Club hoists getClearing() out of loop"     check_H2_club_clearing_hoisted
echo
echo "  negative — old construct removed"
run N1  "old method gone from src/main"         check_N1_old_method_gone_from_main
run N1b "no test still CALLS the old method"    check_N1b_no_test_stubs_old_method
run N2  "area.name IN (:locationNameList) gone" check_N2_old_predicate_gone
run N3  "Transfer Arrays.asList(AREA_...) gone" check_N3_xfer_arraylist_gone
run N4  "Club Arrays.asList(AREA_...) gone"     check_N4_club_arraylist_gone
echo
echo "  §7.2 constant-coupling guard"
run T1  "gate contract test exists"             check_T1_const_test_exists
run T2  "contract test asserts AREA_USERS_NAME"  check_T2_const_test_asserts

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
echo
echo "REMINDER: this script proves code shape only. Per plan §7.4 the SQL predicate"
echo "has no automated coverage — record manual rows M1/M4/M5/M7 before sign-off."

[ "$FAIL" -eq 0 ]
