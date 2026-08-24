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

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v1/wms-api}"
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
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }

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
mvn_test_passes() {
    local test_class=$1 out rc
    out=$(mvn test -Dtest="$test_class" -DfailIfNoTests=false 2>&1); rc=$?
    [ "$rc" -eq 0 ] || return 1
    # a real summary must exist, or nothing ran
    printf '%s' "$out" | grep -qE "Tests run: [0-9]+, Failures: 0, Errors: 0, Skipped: 0" || return 1
    return 0
}

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
echo

# run S1  "S1 — cancelBatch helper invoked"          check_S1_helper_invoked
# run S1b "S1 — cancelBatch acquires findByIdForUpdate" check_S1_lock_at_entry
# run S2  "S2 — cancelOrder helper invoked"          check_S2_helper_invoked
# ...

# === Optional: run targeted JUnit tests too ===================================
# A code-shape grep proves the call exists. A targeted test proves it works.
# Both are cheap and complementary.
#
#   run S3-test "S3 unit test passes" mvn_test_passes BillofladingServiceUnitTest

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
