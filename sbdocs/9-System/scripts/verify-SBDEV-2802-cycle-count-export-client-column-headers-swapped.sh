#!/usr/bin/env bash
# verify-SBDEV-2802-cycle-count-export-client-column-headers-swapped.sh
#
# Machine-checkable acceptance for SBDEV-2802 — cycle count export "Client Name" /
# "Client ID" headers are swapped relative to their values.
#
# Plan: sbdocs/1-Projects/wms2/plan/SBDEV-2802-cycle-count-export-client-column-headers-swapped.md
#
# PROJECT_ROOT IS THE REPO ROOT, NOT THE MONOREPO ROOT.
# ------------------------------------------------------
# Unlike most scripts in this directory (which are monorepo-rooted and assert
# against `v2/wms2-api/src/...`, and therefore need the symlink shadow-root
# recipe in the wms-plan-executor skill), this one is rooted at the wms2-api
# repo itself and asserts against `src/...`. So point it straight at the
# worktree — no shadow root, and no way to accidentally grade the stale main
# checkout:
#
#   PROJECT_ROOT=/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-2802 \
#     bash sbdocs/9-System/scripts/verify-SBDEV-2802-cycle-count-export-client-column-headers-swapped.sh
#
# Exit 0 iff every check passes.
#
# Assertion style
# ---------------
# Every code-shape check is a single-line grep against a named file. `grep` on a
# missing file exits non-zero, so these FAIL CLOSED — deliberately avoiding the
# `perl -0777 -ne` multi-line helpers in verify-plan-template.sh, which exit 0
# when they cannot open the file and therefore false-green every assertion about
# a file that does not exist.
#
# Baselines (against origin/develop @ a0846d1, the PR #121 merge):
#   pre-fix                                   → A1,A2,A3a,A3b,A3c,A5*,A8* fail
#   correct fix                               → all pass
#   wrong fix (values swapped, labels intact) → A4a/A4b/A4c fail
# Re-baseline if you change a count. A `0 fail` on unmodified code means the
# script asserts nothing.
#
# A6 is an INVARIANT before the TDD step and a fix-detector after it: the suite is
# green on develop, so A6 passes pre-fix; once the §3.2 alignment test is added it
# fails until §3.1 lands. Read a pre-fix A6 pass as "suite intact", not "fix done".

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

# Monorepo root — only for the sbdocs-side sibling-script check (A8). Independent
# of PROJECT_ROOT because sbdocs/ is not part of any sub-repo worktree.
MONO="${MONO:-/home/nampark/dev/wms-claude}"

SVC="src/main/java/net/aim_ai/wms/service/CyclecountService.java"
TST="src/test/java/net/aim_ai/wms/unit/controller/CycleCountControllerUnitTest.java"
SIB="$MONO/sbdocs/9-System/scripts/verify-SBDEV-2632-cycle-count-bulk-export-nonnumeric-id-500.sh"

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    local id=$1 desc=$2 reason=$3
    printf "  SKIP  %-10s  %s  (%s)\n" "$id" "$desc" "$reason"; SKIP=$((SKIP+1))
}

# run_mvn — SKIP when maven is not on PATH rather than reporting a false FAIL.
# (SDKMAN: export PATH="$HOME/.sdkman/candidates/maven/current/bin:$HOME/.sdkman/candidates/java/current/bin:$PATH")
#
# WARNING: a SKIP here is not a pass. A6 is the ONLY behavioral assertion in this
# script — everything else is a code-shape grep. A run that skips A6/A7 has not
# demonstrated the fix works; say so when reporting the result.
run_mvn() {
    local id=$1 desc=$2; shift 2
    if ! command -v mvn >/dev/null 2>&1; then
        skip "$id" "$desc" "mvn not on PATH — behavioral coverage NOT demonstrated"; return
    fi
    run "$id" "$desc" "$@"
}

file_exists() { [ -f "$1" ]; }

# occurrences <pattern> <file> — count of matches, not matching LINES. Using
# `grep -c` here would under-report if two literals ever share a line.
occurrences() {
    local pattern=$1 file=$2
    [ -f "$file" ] || return 1
    grep -o -F -- "$pattern" "$file" 2>/dev/null | grep -c . || true
}

count_eq() {
    local expected=$1 pattern=$2 file=$3
    [ -f "$file" ] || return 1
    [ "$(occurrences "$pattern" "$file")" -eq "$expected" ]
}

count_ge() {
    local minimum=$1 pattern=$2 file=$3
    [ -f "$file" ] || return 1
    [ "$(occurrences "$pattern" "$file")" -ge "$minimum" ]
}

file_contains()     { [ -f "$2" ] && grep -q -F -- "$1" "$2"; }
file_not_contains() { [ -f "$2" ] && ! grep -q -F -- "$1" "$2"; }
file_contains_re()  { [ -f "$2" ] && grep -qE -- "$1" "$2"; }

# --- A1: all six header arrays carry the corrected order ----------------------
# Six arrays across three methods: exportCycleCounts (aggregated + detailed),
# exportCycleCount (aggregated + detailed), exportCycleCount2 (aggregated +
# detailed). count_eq 6 (not >=1) is what catches a 3-of-6 partial fix.
check_A1() { count_eq 6 '"Client ID", "Client Name"' "$SVC"; }

# --- A2: no header array retains the swapped order ---------------------------
check_A2() { file_not_contains '"Client Name", "Client ID"' "$SVC"; }

# --- A3: the obsolete bug-parity comment is gone, ENTIRELY -------------------
# The comment is six lines; only the first carries "deliberate bug-parity".
# Deleting just that line would green a single-phrase check while lines 2-3
# survive, still asserting the labels ARE swapped — now false, and exactly the
# misdirection the deletion exists to remove. A2 does not catch it either: those
# lines mention both labels but not adjacently. So pin three distinct phrases.
check_A3a() { file_not_contains 'deliberate bug-parity' "$SVC"; }
check_A3b() { file_not_contains 'swapped relative to the values' "$SVC"; }
check_A3c() { file_not_contains 'do not "fix" in isolation' "$SVC"; }

# --- A4: NO value order was changed ------------------------------------------
# The fix swaps labels only; every value emission must still put clNr before
# name. This is the guard against an implementation that "fixed" the values
# instead and left the labels alone — which would silently shift what lives in
# each spreadsheet column while the header row looked untouched.
#
# Two distinct shapes, calibrated against origin/develop @ a0846d1:
#   exportCycleCounts (added by SBDEV-2632)  inline array   2x
#   exportCycleCount / exportCycleCount2     row[n] =       2x row[0]/row[1]
#                                                           2x row[2]/row[3]
check_A4_inline()      { count_eq 2 'client.getClNr(), client.getName()' "$SVC"; }
check_A4_legacy_agg()  { count_eq 2 'row[0] = client.getClNr();' "$SVC" && \
                         count_eq 2 'row[1] = client.getName();' "$SVC"; }
check_A4_legacy_det()  { count_eq 2 'row[2] = client.getClNr();' "$SVC" && \
                         count_eq 2 'row[3] = client.getName();' "$SVC"; }

# --- A5: the alignment regression test exists AND asserts something ----------
# A signature-only grep is not enough: the plan's own §3.2 snippet would satisfy
# it with an empty body, and a comment mentioning indexOf would satisfy a naive
# lookup grep. So require the fixture values to appear MORE times than the
# fixture itself uses them (1x each in stubClientAndItem), which only a real
# assertion can do, and require one header lookup per sheet.
check_A5_test_present() { file_contains_re 'void export_clientColumnsAlignWithTheirHeaders' "$TST"; }
check_A5_by_lookup()    { count_ge 2 'indexOf("Client' "$TST"; }
check_A5_asserts_clnr() { count_ge 2 '"CLI-001"' "$TST"; }
check_A5_asserts_name() { count_ge 2 '"WineCo"' "$TST"; }

# --- A5e: the old verbatim pin no longer asserts the swapped order ----------
# This literal is a substring of BOTH pinned lines (aggregated + detailed), so
# file_not_contains fails if either is left unfixed.
check_A5e() { file_not_contains '"Client Name", "Client ID", "SKU ID"' "$TST"; }

# --- A6/A7: behavior, not shape ---------------------------------------------
# Bare class name on purpose: CycleCountControllerUnitTest is @Nested, and
# -Dtest='Class#method' silently runs ZERO tests and reports a false green.
#
# Do NOT add -q: it suppresses INFO, which is where both "BUILD SUCCESS" and
# Surefire's "Tests run:" summary live, so a -q run has nothing to grep and the
# check can never pass. Verified 2026-08-03: `mvn -q validate` emits 0 lines.
# Requiring "Tests run: [1-9]" also closes the -DfailIfNoTests=false hole where a
# mistyped class name runs zero tests and exits 0.
check_A6() {
    local out
    out=$(mvn test -Dtest=CycleCountControllerUnitTest -DfailIfNoTests=false 2>&1) || return 1
    printf '%s' "$out" | grep -qE "Tests run: [1-9][0-9]*, Failures: 0, Errors: 0"
}
check_A7() { mvn clean compile -q; }

# --- A8: the sibling SBDEV-2632 verify script no longer contradicts this fix --
# SBDEV-2632's plan is status:implemented but NOT archived, so its script is
# still live — and it asserts the SWAPPED order at :235-236. After this fix it
# would fail, and the natural "repair" is to revert this change. Retire or
# update it as part of this pass. Skipped when the file is already gone (i.e.
# SBDEV-2632 was archived, which also retires its script).
# Fixed-string, NOT regex: the sibling script stores its assertion as a grep
# PATTERN, so the literal characters in the file are `"Client Name",\s*"Client
# ID"` — backslash-s-star, not whitespace. An ERE search for \s* silently fails
# to match and the check false-greens. (Caught in re-baselining, 2026-08-03.)
check_A8a() {
    [ -f "$SIB" ] || return 0   # already archived/retired → nothing to contradict
    ! grep -q -F '"Client Name",\s*"Client ID"' "$SIB"
}
check_A8b() {
    [ -f "$SIB" ] || return 0
    ! grep -q -F '"Date",\s*"Client Name"' "$SIB"
}

# === Runner ==================================================================
echo
echo "verify-SBDEV-2802 — cycle count export client column headers"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  (repo root, not monorepo root — see header)"
echo

run  A0   "CyclecountService.java present at expected path" file_exists "$SVC"
run  A0b  "CycleCountControllerUnitTest.java present"       file_exists "$TST"
echo
run  A1   "all 6 header arrays read \"Client ID\", \"Client Name\""  check_A1
run  A2   "no header array retains \"Client Name\", \"Client ID\""   check_A2
run  A3a  "bug-parity NOTE removed (phrase 1/3)"                     check_A3a
run  A3b  "bug-parity NOTE removed (phrase 2/3 — whole block)"       check_A3b
run  A3c  "bug-parity NOTE removed (phrase 3/3 — whole block)"       check_A3c
echo
run  A4a  "values untouched — inline getClNr(), getName() still 2x"  check_A4_inline
run  A4b  "values untouched — legacy row[0]/row[1] still 2x"         check_A4_legacy_agg
run  A4c  "values untouched — legacy row[2]/row[3] still 2x"         check_A4_legacy_det
echo
run  A5a  "alignment test export_clientColumnsAlignWithTheirHeaders exists" check_A5_test_present
run  A5b  "asserts via header indexOf on both sheets (>=2)"          check_A5_by_lookup
run  A5c  "asserts the clNr fixture value (>=2 incl. stub)"          check_A5_asserts_clnr
run  A5d  "asserts the name fixture value (>=2 incl. stub)"          check_A5_asserts_name
run  A5e  "stale verbatim header pin updated"                        check_A5e
echo
run  A8a  "sibling SBDEV-2632 script: aggregated pin updated"         check_A8a
run  A8b  "sibling SBDEV-2632 script: detailed pin updated"           check_A8b
echo
run_mvn A6 "CycleCountControllerUnitTest passes (bare class name)"   check_A6
run_mvn A7 "mvn clean compile succeeds"                              check_A7

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
echo
if [ "$SKIP" -gt 0 ]; then
    echo "NOTE: A6 is the only behavioral check here. A skipped A6 means the fix's"
    echo "      behavior was NOT demonstrated — report the skip, don't imply a pass."
fi
echo "REMINDER: 'mvn test' mutates tracked src/test/resources/archunit_store/ —"
echo "          revert it before committing."

[ "$FAIL" -eq 0 ]
