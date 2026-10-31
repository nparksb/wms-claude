#!/usr/bin/env bash
# verify-<plan-id>.sh — machine-checkable acceptance for <plan-title>
#
# Purpose
# -------
# Closes the over-claim gap: an executor agent (or human) can claim a rollout
# item is "DONE" without it actually being in the code. This script encodes
# each plan item as a grep/test assertion. Run after every implementation pass:
#
#   $ bash sbdocs/9-System/scripts/verify-<plan-id>.sh
#
# Exit code is 0 if all checks pass, non-zero otherwise. The agent's
# end-of-task report MUST paste this script's output before the work is
# accepted.
#
# Design rules
# ------------
# 1. Every rollout item gets at least one POSITIVE check: "the new construct
#    appears at the right call-site." Use the most specific regex you can
#    write (a literal method-name + first arg is usually enough).
#
# 2. For sites that REPLACE old code, add a NEGATIVE check: "the old
#    construct is gone." This catches the failure mode where an agent
#    adds the new code in the wrong place and leaves the old code intact.
#
# 3. Prefer file-scoped greps over project-wide greps. A project-wide grep
#    will match imports / comments / test fixtures elsewhere — useless as
#    proof of correctness at the actual call-site.
#
# 4. Each check should produce ONE line of output ("PASS  <id>  <desc>")
#    so the script's output is easy to scan. The `run` helper handles this.
#
# 5. Don't make checks too brittle. A regex that only matches one exact
#    formatting will fail on benign reformats. Use `\s+` for whitespace
#    runs, escape special regex chars, and pick patterns the agent can
#    reasonably preserve.
#
# 6. If a check needs to validate behavior (not just code shape), add it
#    as a JUnit test in src/test/ instead and have this script invoke
#    `mvn test -Dtest=<TestClass>`. Code-shape greps are necessary but not
#    sufficient — they prove the call exists, not that it works.
#
# Conventions
# -----------
# - Place this file at `sbdocs/9-System/scripts/verify-<plan-id>.sh`.
# - The plan document references this script's path in its "## Acceptance"
#   section (see wms-plan-template.md).
# - Run from the v1/wms-api project root by default; override with
#   PROJECT_ROOT=... for v2/wms2-api or other targets.
# - Maven rows inherit the caller's environment: JAVA_HOME and PATH must reach the
#   repo's JDK (21 for wms2-api, 8 for v1) and `mvn`, or every maven row FAILs for
#   a reason unrelated to the code. Check `mvn -v` before trusting a red maven row.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/v1/wms-api}"   # owl root from this file (templates/ or scripts/ alike): same on Mac and Linux; set the suffix to your repo
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

# run <id> <description> <command...>
# Invokes the command. Exit code 0 → PASS, non-zero → FAIL.
run() {
    local id=$1
    local desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-8s  %s\n" "$id" "$desc"
        PASS=$((PASS+1))
    else
        printf "  FAIL  %-8s  %s\n" "$id" "$desc"
        FAIL=$((FAIL+1))
    fi
}

# skip <id> <description> <reason>
# Acknowledges a check exists but is intentionally not run today.
skip() {
    local id=$1
    local desc=$2
    local reason=$3
    printf "  SKIP  %-8s  %s  (%s)\n" "$id" "$desc" "$reason"
    SKIP=$((SKIP+1))
}

# --- assertion helpers (used inside check functions) ---

# Match a regex (extended) anywhere in a file.
file_contains() { grep -qE "$1" "$2"; }

# Match a regex on at least N lines of a file.
file_contains_n_times() {
    local pattern=$1 file=$2 n=$3
    local count
    count=$(grep -cE "$pattern" "$file" 2>/dev/null || echo 0)
    [ "$count" -ge "$n" ]
}

# Assert a regex does NOT appear (anywhere uncommented).
#
# The `[ -f "$2" ]` guard is MANDATORY, not defensive. Without it this helper FAILS OPEN: grep exits
# non-zero on a file that does not exist, `!` inverts that to success, and the row reports PASS —
# "the forbidden pattern is gone" — when nothing was examined at all. That is the worst failure mode
# a verify row has, because a refactor that moves or renames the file turns the assertion green in
# the same run that should have caught it. Every positive helper here already fails closed (grep
# exits 2), so only the negated ones need this.
# ⚠ Both guards are load-bearing. `[ -f ]` because `! grep` on a MISSING file returns PASS (51 scripts
# inherited that bug). `[ -r ]` because on an UNREADABLE file grep exits 2 writing to stderr, the `-q`
# sees no match, and `!` inverts that to PASS as well — measured 2026-08-27 via `chmod 000`.
file_not_contains() { [ -f "$2" ] && [ -r "$2" ] || return 1; ! grep -qE "$1" "$2"; }

# code_not_contains <regex> <file> — file_not_contains, but ignoring COMMENT-ONLY lines (//, *, /*, #).
#
# ⚠ USE THIS, NOT file_not_contains, FOR ANY NEGATIVE ROW ABOUT A DELETED SYMBOL. A good deletion leaves
# a tombstone comment naming the thing it removed, and that comment satisfies a plain negative grep — so
# the row goes RED against correct code. Measured on SBDEV-3017: the row asserting the legacy
# setPutAwayLocation endpoint was gone went red purely on its own tombstone. A sibling row survived only
# because the tombstone happened to capitalise one letter differently than the pattern — i.e. by luck.
#
# Direction of the residual gap is safe: a TRAILING comment on a code line (`foo(); // setPutAwayLocation`)
# still counts as code, so this can false-RED but never false-GREEN.
code_not_contains() {
    [ -f "$2" ] && [ -r "$2" ] || return 1
    ! grep -vE '^[[:space:]]*(//|\*|/\*|#)' "$2" | grep -qE "$1"
}

# A specific method must exist on a class-file.
class_has_method() {
    local file=$1 signature_regex=$2
    grep -qE "$signature_regex" "$file"
}

# A maven test class exists and currently passes.
#
# Use the EXIT CODE, never a grep of the output. The previous version passed `-q` and then grepped
# for "BUILD SUCCESS|Tests run..." — but `-q` suppresses exactly those lines, so the grep never
# matched and every maven row was PERMANENTLY RED in every script generated from this template.
# A permanently-red row is indistinguishable from honest work-not-done, which is how it survived.
#
# `Skipped: 0` is additionally required so a @Disabled class cannot certify itself green, and
# `-DfailIfNoTests=false` means a typo'd class name would otherwise pass silently — hence the
# explicit check that a surefire summary was actually produced.
#
# SBDEV-3014 closed more holes. Surefire prints one summary line per class AND one aggregate, so:
#   * ANY summary line reporting a failure, error, skip or flake fails the row — one clean line must
#     not outvote a @Disabled sibling, and maven can exit 0 with failures under
#     maven.test.failure.ignore (MAVEN_OPTS / settings.xml).
#   * The largest clean count must reach the minimum ($2, default 1, must be >= 1). The OUTER class of
#     @Nested tests prints `Tests run: 0, ...`, which alone used to pass with every nested class deleted.
#   * Pass ONE exact class name. With a pattern or a comma list, the minimum can be met by another
#     class's line or by the aggregate.
# `-B` (batch mode) keeps ANSI colour out of the numbers being grepped.
#
# usage: mvn_test_passes <TestClass> [min-test-count]   (exit 2 = usage error, not a test failure)
mvn_test_passes() {
    local test_class=$1 min=${2:-1} out rc summary count
    # `[ -ge ]` also rejects a non-integer (it errors), so this one test covers 0, -5 and 'abc'
    [ "$min" -ge 1 ] 2>/dev/null || { echo "mvn_test_passes: min must be an integer >= 1, got '$min'" >&2; return 2; }
    archunit_store_snapshot
    out=$(mvn -B test -Dtest="$test_class" -DfailIfNoTests=false 2>&1); rc=$?
    [ "$rc" -eq 0 ] || return 1
    summary=$(printf '%s\n' "$out" | grep -E "Tests run: [0-9]+, Failures: [0-9]+, Errors: [0-9]+, Skipped: [0-9]+")
    printf '%s\n' "$summary" | grep -qE "(Failures|Errors|Skipped|Flakes): [1-9]" && return 1
    count=$(printf '%s\n' "$summary" | grep -oE "Tests run: [0-9]+" | grep -oE "[0-9]+" | sort -rn | head -1)
    [ -n "$count" ] && [ "$count" -ge "$min" ]
}

# `mvn test` rewrites the tracked ArchUnit freeze store (wms2-api), and with allowStoreCreation=true can
# add untracked files to it, so a clean-tree check after a verify run shows spurious changes. Snapshot
# before the first maven row; restore at exit ONLY if the store was clean then (untracked files count) —
# a deliberate uncommitted store change in the tree under test must survive. A store that did not exist
# is removed again if maven created it. Outside a git repo both are no-ops. The path is recorded
# absolutely at snapshot time, so a later `cd` cannot aim the restore at the wrong tree; a snapshot
# taken inside a subshell is lost, which is why the driver below also snapshots at top level.
ARCHUNIT_STORE=src/test/resources/archunit_store
archunit_store_snapshot() {
    [ -n "${ARCHUNIT_WAS_CLEAN:-}" ] && return 0
    ARCHUNIT_STORE_PARENT="$(pwd)/$(dirname "$ARCHUNIT_STORE")"
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        ARCHUNIT_WAS_CLEAN=no
    elif [ ! -e "$ARCHUNIT_STORE" ]; then
        # deleted-but-tracked is the re-freeze workflow, not "absent": leave maven's output to the user.
        # Check HEAD as well as the index — `git rm` empties the index but HEAD still has the store.
        if [ -z "$(git ls-files -- "$ARCHUNIT_STORE" 2>/dev/null)" ] \
            && [ -z "$(git ls-tree -r --name-only HEAD -- "$ARCHUNIT_STORE" 2>/dev/null)" ]; then
            ARCHUNIT_WAS_CLEAN=absent
        else
            ARCHUNIT_WAS_CLEAN=no
        fi
    # --untracked-files=all: status.showUntrackedFiles=no would otherwise hide a user's file, read as
    # "clean", and let the restore's `git clean` delete something git never had a copy of
    elif [ -z "$(git status --porcelain --untracked-files=all -- "$ARCHUNIT_STORE" 2>/dev/null)" ]; then
        ARCHUNIT_WAS_CLEAN=yes
    else
        ARCHUNIT_WAS_CLEAN=no
    fi
}
archunit_store_restore() {
    local base
    base=$(basename "$ARCHUNIT_STORE")
    # The snapshot is taken once, so a store edit made DURING a long maven run is reverted too — every
    # removal is named on stderr (`git clean -n`) so nothing disappears silently.
    case "${ARCHUNIT_WAS_CLEAN:-}" in
        yes)    git -C "$ARCHUNIT_STORE_PARENT" checkout HEAD -- "$base" 2>/dev/null
                git -C "$ARCHUNIT_STORE_PARENT" clean -nd -- "$base" >&2 2>/dev/null
                git -C "$ARCHUNIT_STORE_PARENT" clean -fdq -- "$base" 2>/dev/null ;;
        absent) [ -e "$ARCHUNIT_STORE_PARENT/$base" ] || return 0
                git -C "$ARCHUNIT_STORE_PARENT" clean -nd -- "$base" >&2 2>/dev/null
                git -C "$ARCHUNIT_STORE_PARENT" clean -fdq -- "$base" 2>/dev/null ;;
    esac
    return 0
}
# Never trust snapshot state exported by a parent shell.
ARCHUNIT_WAS_CLEAN=
ARCHUNIT_STORE_PARENT=

# === Per-rollout-item checks ==================================================
# Replace the examples below with one check function per rollout item in your
# plan. Naming convention: check_<rollout-id>_<aspect> ()
#
# Example for a hypothetical S3 (closeBOL afterCommit):
#
#   check_S3_helper_invoked() {
#       file_contains 'OmsNotificationHelper\.deferToCommit\("closeBOL"' \
#           src/main/java/net/aim_ai/wms/service/BillofladingService.java
#   }
#
#   check_S3_inline_post_gone() {
#       file_not_contains 'Map<String, String> respMap = httpRestService\.post\(urlPath, payload\);' \
#           src/main/java/net/aim_ai/wms/service/BillofladingService.java
#   }
#
# === Wire into the runner ====================================================
# Each call to `run` produces one PASS/FAIL line. Group related checks together
# (e.g., all checks for the same site, then a blank `echo` separator) so the
# output reads like a per-site checklist.

echo
echo "verify-<plan-id> — running acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"

# Snapshot at top level (a snapshot inside a subshell is lost) and restore on ANY exit — an early
# `exit`, an unbound variable under `set -u`, or Ctrl-C would otherwise leave the store rewritten.
#
# ⚠ Bash keeps ONE EXIT trap per shell. Need your own exit cleanup? ADD it to verify_on_exit — never
# call `trap ... EXIT` again, or the store restore (or your cleanup) is silently dropped.
verify_on_exit() {
    archunit_store_restore
}
archunit_store_snapshot
trap verify_on_exit EXIT
echo

# run S1  "S1 — cancelBatch helper invoked"          check_S1_helper_invoked
# run S1b "S1 — cancelBatch acquires findByIdForUpdate" check_S1_lock_at_entry
# run S2  "S2 — cancelOrder helper invoked"          check_S2_helper_invoked
# ...

# === Optional: run targeted JUnit tests too ===================================
# A code-shape grep proves the call exists. A targeted test proves it works.
# Both are cheap and complementary.
#
#   run S3-test "S3 unit test passes" mvn_test_passes BillofladingServiceUnitTest 4

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
