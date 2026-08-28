#!/usr/bin/env bash
# Tests for the shared assertion helpers in sbdocs/9-System/templates/verify-plan-template.sh
#
# WHY THIS EXISTS: 128 verify scripts are generated from that template and inherit its helpers.
# Two of them are wrong, and both failure modes are ones a human reads as an honest result:
#   * file_not_contains FAILS OPEN on a missing file -> a negative assertion about a file that was
#     moved, renamed or never created reports PASS ("the bad pattern is gone") when nothing was checked.
#   * mvn_test_passes greps for strings that its own `-q` flag suppresses -> permanently FAIL, which
#     reads as "the test doesn't pass" rather than "this row is broken".
#
# Run: bash sbdocs/9-System/templates/test-verify-plan-template-helpers.sh   (exit 0 = helpers behave)
#
# Mutation-checked 2026-08-21 — each fix has a test that reds when the fix is removed:
#   M1  drop the -f guard from file_not_contains        -> "MUST FAIL CLOSED on a missing file" reds
#   M2  drop the summary requirement from mvn_test_passes -> the two REFUSES cases red
#   M3  restore the original -q + grep form             -> the skips case reds
# Honest limit: a stub mvn controls its own output, so this cannot simulate `-q` suppressing REAL
# maven output. What it does pin is the contract — exit code AND a verified surefire summary.
set -uo pipefail
TEMPLATE="${TEMPLATE:-/home/nampark/dev/wms-claude/sbdocs/9-System/templates/verify-plan-template.sh}"

# Source only the helper definitions, not the template's driver/echo lines.
HELPERS=$(mktemp); trap 'rm -f "$HELPERS"' EXIT
sed -n '/^# --- assertion helpers/,/^# === Per-rollout-item checks/p' "$TEMPLATE" \
  | grep -v '^# === Per-rollout-item checks' > "$HELPERS"
# shellcheck disable=SC1090
. "$HELPERS"

T_PASS=0; T_FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; T_PASS=$((T_PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; T_FAIL=$((T_FAIL+1)); }
check(){ # description, expected(0|1), actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected exit $2, got $3)"; fi
}
# The run() wrapper only distinguishes zero from non-zero, so "fails closed" means ANY non-zero.
# grep exits 2 on a missing file, which is a legitimate fail-closed. Asserting exactly 1 here was a
# bug in this test, not in the helper.
check_nonzero(){ # description, actual
  if [ "$2" -ne 0 ]; then ok "$1 (exit $2)"; else bad "$1 — returned 0, i.e. it FAILED OPEN"; fi
}

MISSING=/tmp/.definitely-not-a-real-file-$$
REAL=$(mktemp); printf 'hello world\nforbidden_token here\n' > "$REAL"

echo "── file_not_contains"
file_not_contains 'forbidden_token' "$REAL"; check "reports absent=false when the token IS present" 1 $?
file_not_contains 'nope_not_here'   "$REAL"; check "reports absent=true when the token is absent"   0 $?
file_not_contains 'anything' "$MISSING" 2>/dev/null; check_nonzero "MUST FAIL CLOSED on a missing file" $?
UNREADABLE="$(dirname "$REAL")/unreadable_$$.java"
printf 'void f(){ forbidden_token(); }\n' > "$UNREADABLE"; chmod 000 "$UNREADABLE"
file_not_contains 'forbidden_token' "$UNREADABLE" 2>/dev/null
check_nonzero "MUST FAIL CLOSED on an UNREADABLE file (grep exits 2; ! inverts it to a false PASS)" $?
chmod 644 "$UNREADABLE"

echo "── code_not_contains (negatives about DELETED symbols)"
printf '// tombstone: setPutAwayLocation was DELETED here\nvoid keep(){ }\n' > "$REAL"
code_not_contains 'setPutAwayLocation' "$REAL"
check "IGNORES a comment-only line — the tombstone trap that reds a correct deletion" 0 $?
printf '// tombstone: setPutAwayLocation was DELETED here\nvoid f(){ setPutAwayLocation(a,b); }\n' > "$REAL"
code_not_contains 'setPutAwayLocation' "$REAL"
check "still CATCHES the symbol on a real code line"                                  1 $?
printf ' * setPutAwayLocation in a javadoc continuation\n' > "$REAL"
code_not_contains 'setPutAwayLocation' "$REAL"
check "IGNORES a javadoc continuation line"                                            0 $?
code_not_contains 'anything' "$MISSING" 2>/dev/null
check_nonzero "MUST FAIL CLOSED on a missing file"                                      $?
chmod 000 "$UNREADABLE"; code_not_contains 'forbidden_token' "$UNREADABLE" 2>/dev/null
check_nonzero "MUST FAIL CLOSED on an UNREADABLE file"                                  $?
chmod 644 "$UNREADABLE"; rm -f "$UNREADABLE"
printf 'forbidden_token\n' > "$REAL"
echo "── file_not_contains (resumed)"


echo "── file_contains (control: should already fail closed)"
file_contains 'forbidden_token' "$REAL";    check "finds a present token"            0 $?
file_contains 'anything' "$MISSING" 2>/dev/null; check_nonzero "fails closed on a missing file" $?

echo "── mvn_test_passes"
# Contract: exit 0 AND a surefire summary showing 0 failures, 0 errors, 0 skipped.
# "exit 0 with no output" must NOT pass: with -DfailIfNoTests=false a typo'd class name exits 0
# having run nothing, and a row that greens on zero tests is worse than no row.
mvn() { echo "Tests run: 12, Failures: 0, Errors: 0, Skipped: 0"; return 0; }
mvn_test_passes SomeTest; check "passes on exit 0 + a clean summary"                    0 $?
mvn() { return 0; }
mvn_test_passes SomeTest; check "REFUSES exit 0 with no summary (nothing actually ran)" 1 $?
mvn() { echo "Tests run: 12, Failures: 1, Errors: 0, Skipped: 0"; return 1; }
mvn_test_passes SomeTest; check "fails on a real test failure"                          1 $?
mvn() { echo "Tests run: 12, Failures: 0, Errors: 0, Skipped: 3"; return 0; }
mvn_test_passes SomeTest; check "REFUSES a summary with skips (@Disabled cannot self-certify)" 1 $?
unset -f mvn

rm -f "$REAL"
echo
echo "Result: $T_PASS pass, $T_FAIL fail"
[ "$T_FAIL" -eq 0 ]
