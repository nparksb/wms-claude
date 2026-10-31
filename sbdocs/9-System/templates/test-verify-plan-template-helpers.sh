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
# Mutation-checked 2026-10-31 (SBDEV-3014), each killed by the case named:
#   M4  drop the any-line `Skipped: [1-9]` check         -> "REFUSES when ANY summary line reports skips"
#   M5  default the minimum to 0                          -> "REFUSES a zero-test summary"
#   M6  ignore the min-count argument                     -> "REFUSES when the count is below the minimum"
#   M7  restore even when the store was already dirty     -> "leaves a store that was ALREADY dirty alone"
#   M8  make archunit_store_restore a no-op               -> "restores a store that was clean before maven"
# Review-round mutants (same day), each killed by the case named:
#   M10 drop Failures|Errors from the per-line check      -> "REFUSES a failing sibling line even when maven exits 0"
#   M11 drop Flakes                                        -> "REFUSES flakes"
#   M12 grade every output line, not surefire summaries    -> "ignores a non-surefire log line"
#   M13 allow min=0                                        -> "REFUSES min=0"
#   M15 clean check ignores untracked files                -> "keeps an untracked store file that predates maven"
#   M16 restore without `git clean`                        -> "removes an untracked file maven added"
#   M17 record the store path relatively                   -> "restores by absolute path after a cd"
#   M18 never remove a store maven created                 -> "removes a store maven created from nothing"
#   M20 drop --untracked-files=all                         -> "keeps a user file when status.showUntrackedFiles=no"
#   M21 treat a tracked-but-deleted store as absent        -> "leaves a deliberately re-frozen store alone"
#   M22 clean without naming the removals                  -> "names each file it removes on stderr"
#   M23 skip the on-load state reset                       -> "resets inherited snapshot state on load"
#   M25 drop the HEAD check from the absent test           -> "leaves a store re-frozen via 'git rm' alone"
# Not covered here: the driver's `trap verify_on_exit EXIT` (this file sources helpers only).
# Checked end-to-end by hand 2026-10-31 with a PATH-stub mvn: an unbound-variable abort exits 1 with the
# store back at `orig`; a red row still exits 1 (the trap does not mask FAIL); with the trap removed
# the store stayed `mutated`.
# Honest limit: a stub mvn controls its own output, so this cannot simulate `-q` suppressing REAL
# maven output. What it does pin is the contract — exit code AND a verified surefire summary.
set -uo pipefail
TEMPLATE="${TEMPLATE:-$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify-plan-template.sh}"

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
# SBDEV-3014: surefire prints `Tests run: 0` for the OUTER class of @Nested tests, so a zero-count
# summary alone must not pass — deleting every nested class would otherwise still score green.
mvn() { echo "Tests run: 0, Failures: 0, Errors: 0, Skipped: 0"; return 0; }
mvn_test_passes SomeTest; check "REFUSES a zero-test summary (outer @Nested class only)" 1 $?
mvn() { printf '%s\n' "Tests run: 0, Failures: 0, Errors: 0, Skipped: 0" \
    "Tests run: 5, Failures: 0, Errors: 0, Skipped: 0" "Tests run: 5, Failures: 0, Errors: 0, Skipped: 0"; return 0; }
mvn_test_passes SomeTest; check "passes @Nested output (outer 0 + nested 5)"            0 $?
# One clean line must not outvote a sibling line that reports skips (a @Disabled nested class).
mvn() { printf '%s\n' "Tests run: 3, Failures: 0, Errors: 0, Skipped: 0" \
    "Tests run: 2, Failures: 0, Errors: 0, Skipped: 2" "Tests run: 5, Failures: 0, Errors: 0, Skipped: 2"; return 0; }
mvn_test_passes SomeTest; check "REFUSES when ANY summary line reports skips"           1 $?
mvn() { echo "Tests run: 5, Failures: 0, Errors: 0, Skipped: 0"; return 0; }
mvn_test_passes SomeTest 5; check "passes when the count meets the minimum (5 >= 5)"    0 $?
mvn_test_passes SomeTest 6; check "REFUSES when the count is below the minimum (5 < 6)" 1 $?
# Review M2: maven can exit 0 with failures (maven.test.failure.ignore via MAVEN_OPTS/settings.xml).
mvn() { printf '%s\n' "Tests run: 0, Failures: 0, Errors: 0, Skipped: 0" \
    "Tests run: 3, Failures: 0, Errors: 0, Skipped: 0" "Tests run: 2, Failures: 1, Errors: 0, Skipped: 0"; return 0; }
mvn_test_passes SomeTest; check "REFUSES a failing sibling line even when maven exits 0" 1 $?
mvn() { echo "Tests run: 4, Failures: 0, Errors: 0, Skipped: 0, Flakes: 1"; return 0; }
mvn_test_passes SomeTest; check "REFUSES flakes (a rerun-to-green test is not acceptance)" 1 $?
# Review L7: only SUREFIRE summary lines are graded — an app log line mentioning skips is not one.
mvn() { printf '%s\n' "INFO import done. Skipped: 3 rows" "Tests run: 4, Failures: 0, Errors: 0, Skipped: 0"; return 0; }
mvn_test_passes SomeTest; check "ignores a non-surefire log line containing 'Skipped: 3'" 0 $?
# Review L2: min=0 would reopen the zero-test hole; a non-number must not look like a test failure.
mvn() { echo "Tests run: 0, Failures: 0, Errors: 0, Skipped: 0"; return 0; }
mvn_test_passes SomeTest 0;   check_nonzero "REFUSES min=0 (would reopen the zero-test hole)" $?
mvn_test_passes SomeTest abc 2>/dev/null; check "REFUSES a non-numeric min as a usage error (exit 2)" 2 $?
unset -f mvn

echo "── archunit_store_restore"
# `mvn test` rewrites the tracked ArchUnit freeze store. Restore it — but ONLY if it was clean before
# the first maven row, so a deliberate uncommitted store change in the tree under test survives.
REPO=$(mktemp -d); STORE=src/test/resources/archunit_store
( cd "$REPO" && git init -q && mkdir -p "$STORE" && echo orig > "$STORE/stored.rules" \
    && git add . && git -c user.name=t -c user.email=t@t commit -qm init )
mvn() { echo mutated > "$STORE/stored.rules"; echo "Tests run: 1, Failures: 0, Errors: 0, Skipped: 0"; return 0; }
( cd "$REPO" && ARCHUNIT_WAS_CLEAN=; mvn_test_passes SomeTest; archunit_store_restore; \
    [ "$(cat "$STORE/stored.rules")" = orig ] ); check "restores a store that was clean before maven" 0 $?
( cd "$REPO" && echo deliberate > "$STORE/stored.rules"; ARCHUNIT_WAS_CLEAN=; mvn_test_passes SomeTest; \
    archunit_store_restore; [ "$(cat "$STORE/stored.rules")" = mutated ] ); check "leaves a store that was ALREADY dirty alone" 0 $?
( cd "$REPO" && git checkout -q -- . && ARCHUNIT_WAS_CLEAN=; archunit_store_restore; \
    [ "$(cat "$STORE/stored.rules")" = orig ] ); check "is a no-op when no maven row ran" 0 $?
# Review M1: allowStoreCreation=true lets ArchUnit add an UNTRACKED file; the tree must end clean.
mvn() { echo new > "$STORE/new-uuid"; echo "Tests run: 1, Failures: 0, Errors: 0, Skipped: 0"; return 0; }
( cd "$REPO" && ARCHUNIT_WAS_CLEAN=; mvn_test_passes SomeTest; archunit_store_restore; \
    [ -z "$(git status --porcelain)" ] ); check "removes an untracked file maven added to a clean store" 0 $?
# ...and an untracked file present BEFORE maven means "not clean" — it must survive.
( cd "$REPO" && echo mine > "$STORE/mine"; ARCHUNIT_WAS_CLEAN=; mvn_test_passes SomeTest; \
    archunit_store_restore; [ -f "$STORE/mine" ] ); check "keeps an untracked store file that predates maven" 0 $?
rm -f "$REPO/$STORE/mine" "$REPO/$STORE/new-uuid"
# Review L3: restore must target the snapshot's directory even if the cwd has since changed.
mvn() { echo mutated > "$STORE/stored.rules"; echo "Tests run: 1, Failures: 0, Errors: 0, Skipped: 0"; return 0; }
( cd "$REPO" && ARCHUNIT_WAS_CLEAN=; mvn_test_passes SomeTest; cd /; archunit_store_restore; \
    [ "$(cat "$REPO/$STORE/stored.rules")" = orig ] ); check "restores by absolute path after a cd" 0 $?
# Review L6: a store maven creates from nothing is removed again.
( cd "$REPO" && git checkout -q HEAD -- . && git clean -fdq && git rm -rq "$STORE" && git -c user.name=t -c user.email=t@t commit -qm rm \
    && ARCHUNIT_WAS_CLEAN=; mkdir -p src/test/resources; \
    mvn() { mkdir -p "$STORE"; echo x > "$STORE/stored.rules"; echo "Tests run: 1, Failures: 0, Errors: 0, Skipped: 0"; }; \
    mvn_test_passes SomeTest; archunit_store_restore; [ ! -e "$STORE" ] ); check "removes a store maven created from nothing" 0 $?
# Review R2-1: with status.showUntrackedFiles=no, `git status --porcelain` hides untracked files, the
# store reads "clean", and `git clean` would delete a user file git never had a copy of.
rm -rf "$REPO"; REPO=$(mktemp -d)   # fresh repo: the L6 case above committed the store's removal
( cd "$REPO" && git init -q && mkdir -p "$STORE" && echo orig > "$STORE/stored.rules" \
    && git add . && git -c user.name=t -c user.email=t@t commit -qm init )
mvn() { echo mutated > "$STORE/stored.rules"; echo "Tests run: 1, Failures: 0, Errors: 0, Skipped: 0"; return 0; }
( cd "$REPO" && git config status.showUntrackedFiles no && echo mine > "$STORE/mine"; ARCHUNIT_WAS_CLEAN=; \
    mvn_test_passes SomeTest; archunit_store_restore; [ -f "$STORE/mine" ] ); check "keeps a user file when status.showUntrackedFiles=no" 0 $?
( cd "$REPO" && git config --unset status.showUntrackedFiles; rm -f "$STORE/mine"; git checkout -q HEAD -- . )
# Review R2-2: a TRACKED store deleted from the tree (the normal re-freeze workflow) is not "absent" —
# maven's regenerated store must be left for the user to commit, not half-deleted.
mvn() { mkdir -p "$STORE"; echo regen > "$STORE/stored.rules"; echo new > "$STORE/new-uuid"; echo "Tests run: 1, Failures: 0, Errors: 0, Skipped: 0"; }
( cd "$REPO" && rm -rf "$STORE" && ARCHUNIT_WAS_CLEAN=; mvn_test_passes SomeTest; archunit_store_restore; \
    [ -f "$STORE/new-uuid" ] && [ "$(cat "$STORE/stored.rules")" = regen ] ); check "leaves a deliberately re-frozen store alone" 0 $?
( cd "$REPO" && rm -f "$STORE/new-uuid"; git checkout -q HEAD -- . )
# Review R3-1: the same re-freeze via `git rm` empties the INDEX too — HEAD still has the store.
( cd "$REPO" && git rm -rq "$STORE" && ARCHUNIT_WAS_CLEAN=; mvn_test_passes SomeTest; archunit_store_restore 2>/dev/null; \
    [ -f "$STORE/new-uuid" ] && [ "$(cat "$STORE/stored.rules")" = regen ] ); check "leaves a store re-frozen via 'git rm' alone" 0 $?
( cd "$REPO" && rm -rf "$STORE"; git reset -q; git checkout -q HEAD -- . )
# Review R2-4: whatever the restore deletes is named on stderr, never removed silently.
mvn() { echo new > "$STORE/new-uuid"; echo "Tests run: 1, Failures: 0, Errors: 0, Skipped: 0"; return 0; }
( cd "$REPO" && ARCHUNIT_WAS_CLEAN=; mvn_test_passes SomeTest; archunit_store_restore 2>&1 >/dev/null | grep -q new-uuid ); \
    check "names each file it removes on stderr" 0 $?
# Review R2-5: state exported by a parent shell must not survive sourcing the helpers.
( export ARCHUNIT_WAS_CLEAN=yes ARCHUNIT_STORE_PARENT=/nowhere; . "$HELPERS"; \
    [ -z "$ARCHUNIT_WAS_CLEAN" ] && [ -z "$ARCHUNIT_STORE_PARENT" ] ); check "resets inherited snapshot state on load" 0 $?
# Outside a git repo both helpers are no-ops (and must not error).
mvn() { echo mutated > "$STORE/stored.rules"; echo "Tests run: 1, Failures: 0, Errors: 0, Skipped: 0"; return 0; }
NOGIT=$(mktemp -d)
( cd "$NOGIT" && mkdir -p "$STORE" && echo orig > "$STORE/stored.rules" && ARCHUNIT_WAS_CLEAN=; \
    mvn_test_passes SomeTest; archunit_store_restore; [ "$(cat "$STORE/stored.rules")" = mutated ] ); check "is a no-op outside a git repo" 0 $?
unset -f mvn; rm -rf "$REPO" "$NOGIT"

rm -f "$REAL"
echo
echo "Result: $T_PASS pass, $T_FAIL fail"
[ "$T_FAIL" -eq 0 ]
