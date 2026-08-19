#!/usr/bin/env bash
# verify-SBDEV-2931-dead-nuxtlogo-spec-fails-yarn-test.sh
# Machine-checkable acceptance for:
#   "wms2-web-ui — dead NuxtLogo spec makes every unfiltered `yarn test` exit non-zero"
#   Plan: sbdocs/1-Projects/wms2/plan/SBDEV-2931-dead-nuxtlogo-spec-fails-yarn-test.md
#
# TARGET REPO: v2/wms2-web-ui  (Nuxt 2 front-end) — NOT wms2-api.
#
# Usage
# -----
#   PROJECT_ROOT=/path/to/v2/wms2-web-ui \
#     bash sbdocs/9-System/scripts/verify-SBDEV-2931-dead-nuxtlogo-spec-fails-yarn-test.sh
#
#   Skip the (slow) Jest rows for a fast shape-only pass:
#     SKIP_JEST=1 PROJECT_ROOT=... bash .../verify-SBDEV-2931-....sh
#
# Expected results  (§9.1 of the plan)
# ------------------------------------
#   pre-fix  (unfixed develop) :  Result: 4 pass, 4 fail, 0 skip   <-- the negative test
#   post-fix (spec deleted)    :  Result: 8 pass, 0 fail, 0 skip
#
# A run that is already 8/0 BEFORE the deletion means the script is not asserting
# anything — investigate the script, not the code.
#
# Design notes — why this script avoids the template's helpers
# ------------------------------------------------------------
# 1. FAIL-CLOSED PATH TESTS. The template's `file_not_contains` runs
#    `! grep -qE "$1" "$2"`. When the file is MISSING, grep exits 2 and `!`
#    turns that into success — a false green. Every check here uses an explicit
#    `[ -e ]` / `[ ! -e ]`, and the guard rows (N2/N3) assert their file EXISTS
#    before inspecting it, so a rename/move reports FAIL rather than PASS.
#
# 2. NO MULTI-LINE PERL. No `perl -0777` helper is used; those exit 0 when they
#    cannot open the target, false-greening every assertion about a file's
#    absence. All assertions here are whole-file existence tests, line-scoped
#    greps, or subprocess exit codes.
#
# 3. NO UNBOUNDED `.*?` GAPS. Nothing in this script uses a lazy cross-line gap,
#    so no assertion can drift and match a construct elsewhere in a file.
#
# 4. JEST EXIT CODE READ DIRECTLY. B3/B4 capture Jest's own status via
#    ${PIPESTATUS[0]} and parse its summary from a captured log. A parse failure
#    fails the row; it cannot masquerade as green.
#
# 5. EVERY `run` ROW CALLS A FUNCTION DEFINED BELOW. An undefined function makes
#    bash exit 127, which `run` records as an ordinary FAIL — indistinguishable
#    from unimplemented work. The row ids and function names were cross-checked
#    against the plan's §9.1 table.
#
# 6. GUARD ROWS ARE LABELLED. N1/N2/N3 guard against the WRONG fix (adding the
#    component, or suppressing the suite via config). They pass before AND after
#    a correct fix by design. They are marked [guard] in their description so a
#    green baseline is never mistaken for the script having teeth. The four
#    DISCRIMINATING rows are A1, A2, A3, B3.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-web-ui}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

SKIP_JEST="${SKIP_JEST:-0}"

# Baseline test count measured on develop 2026-08-12 (plan §1 probe P1/P2).
# B4 is a ratchet: the count must never DROP below this.
BASELINE_TESTS="${BASELINE_TESTS:-251}"

SPEC="test/NuxtLogo.spec.js"
COMPONENT="components/NuxtLogo.vue"
JEST_CONFIG="jest.config.js"
PKG="package.json"

JEST_LOG="$(mktemp -t sbdev2931-jest-XXXXXX.log)"
JEST_STATUS=""
trap 'rm -f "$JEST_LOG"' EXIT

PASS=0
FAIL=0
SKIP=0

# run <id> <description> <fn...>
run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-6s  %s\n" "$id" "$desc"
        PASS=$((PASS+1))
    else
        printf "  FAIL  %-6s  %s\n" "$id" "$desc"
        FAIL=$((FAIL+1))
    fi
}

skip() {
    local id=$1 desc=$2 reason=$3
    printf "  SKIP  %-6s  %s  (%s)\n" "$id" "$desc" "$reason"
    SKIP=$((SKIP+1))
}

# --- Jest driver -------------------------------------------------------------
# Runs the unfiltered suite ONCE and caches the log + exit status, so B3 and B4
# share a single ~12s invocation.
resolve_node() {
    if command -v node >/dev/null 2>&1; then return 0; fi
    # shellcheck disable=SC1090
    if [ -s "$HOME/.nvm/nvm.sh" ]; then . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1; fi
    command -v node >/dev/null 2>&1
}

jest_run_once() {
    [ -n "$JEST_STATUS" ] && return 0
    resolve_node || { JEST_STATUS="no-node"; return 1; }
    [ -x node_modules/.bin/jest ] || { JEST_STATUS="no-jest"; return 1; }
    # UNFILTERED on purpose: no --testPathPattern, no --testPathIgnorePatterns.
    # Filtering here would defeat the entire point of the ticket.
    node_modules/.bin/jest >"$JEST_LOG" 2>&1
    JEST_STATUS="${PIPESTATUS[0]}"
    return 0
}

# --- A1: the dead spec is gone (DISCRIMINATING) ------------------------------
check_A1_spec_deleted() {
    [ ! -e "$SPEC" ]
}

# --- A2: no NuxtLogo reference under test/ or components/ (DISCRIMINATING) ---
check_A2_no_ref_in_test_or_components() {
    local hits=0
    for d in test components; do
        if [ -d "$d" ]; then
            if grep -rqI "NuxtLogo" "$d" 2>/dev/null; then hits=1; fi
        fi
    done
    [ "$hits" -eq 0 ]
}

# --- A3: no NuxtLogo reference anywhere in the repo (DISCRIMINATING) ---------
# Excludes vendored/build dirs; node_modules legitimately contains the string.
check_A3_no_ref_repo_wide() {
    ! grep -rqI "NuxtLogo" . \
        --exclude-dir=node_modules \
        --exclude-dir=.git \
        --exclude-dir=.nuxt \
        --exclude-dir=dist \
        --exclude-dir=coverage \
        2>/dev/null
}

# --- B3: unfiltered Jest is green and exits 0 (DISCRIMINATING) ---------------
check_B3_jest_exits_zero_no_failed_suites() {
    jest_run_once || return 1
    [ "$JEST_STATUS" = "0" ] || return 1
    # Belt and braces: the summary must not report any failed suite.
    grep -qE '^Test Suites:' "$JEST_LOG" || return 1        # fail closed if unparseable
    ! grep -qE '^Test Suites:.*[0-9]+ failed' "$JEST_LOG"
}

# --- B4: no coverage loss — test count never drops below baseline ------------
# Ratchet, not a defect detector: it already passes pre-fix (the dead suite
# contributes 0 tests). It catches an implementer who "greens" the run by
# deleting a LIVE suite.
check_B4_no_test_count_loss() {
    jest_run_once || return 1
    local line count
    line=$(grep -E '^Tests:' "$JEST_LOG" | tail -1) || return 1
    [ -n "$line" ] || return 1
    count=$(printf '%s' "$line" | grep -oE '[0-9]+ total' | grep -oE '[0-9]+')
    [ -n "$count" ] || return 1                              # fail closed if unparseable
    [ "$count" -ge "$BASELINE_TESTS" ]
}

# --- N1 [guard]: fix must be a deletion, not adding the component -----------
check_N1_component_still_absent() {
    [ ! -e "$COMPONENT" ]
}

# --- N2 [guard]: fix must not suppress the suite via jest config ------------
# Asserts the file EXISTS first, so a rename reports FAIL, not a vacuous PASS.
check_N2_jest_config_not_weakened() {
    [ -f "$JEST_CONFIG" ] || return 1
    ! grep -qE 'testPathIgnorePatterns|testMatch|testRegex' "$JEST_CONFIG"
}

# --- N3 [guard]: the documented `yarn test` entrypoint stays unfiltered -----
check_N3_test_script_unfiltered() {
    [ -f "$PKG" ] || return 1
    # The "test" script must still be plain `jest` with no filter flags.
    grep -qE '"test"[[:space:]]*:[[:space:]]*"jest"[[:space:]]*,?' "$PKG" || return 1
    ! grep -qE '"test"[[:space:]]*:[[:space:]]*"[^"]*(testPathIgnorePatterns|testPathPattern)' "$PKG"
}

# === Runner ==================================================================

echo
echo "verify-SBDEV-2931 — dead NuxtLogo spec / unfiltered yarn test exits non-zero"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  BASELINE_TESTS=$BASELINE_TESTS (no-coverage-loss floor)"
echo "  expected: pre-fix 4 pass / 4 fail   ->   post-fix 8 pass / 0 fail"
echo

echo "-- Fix A: the dead spec is gone (discriminating) --"
run A1 "A1 — test/NuxtLogo.spec.js no longer exists"                 check_A1_spec_deleted
run A2 "A2 — no NuxtLogo reference under test/ or components/"       check_A2_no_ref_in_test_or_components
run A3 "A3 — no NuxtLogo reference anywhere in the repo"             check_A3_no_ref_repo_wide
echo

echo "-- Behaviour: the acceptance criteria themselves (discriminating) --"
if [ "$SKIP_JEST" = "1" ]; then
    skip B3 "B3 — unfiltered jest exits 0, 0 failed suites" "SKIP_JEST=1"
    skip B4 "B4 — test count >= $BASELINE_TESTS (no coverage loss)" "SKIP_JEST=1"
else
    run B3 "B3 — unfiltered jest exits 0, 0 failed suites"           check_B3_jest_exits_zero_no_failed_suites
    run B4 "B4 — test count >= $BASELINE_TESTS (no coverage loss)"   check_B4_no_test_count_loss
fi
echo

echo "-- Guards against the WRONG fix (pass pre- AND post-fix by design) --"
run N1 "N1 [guard] — components/NuxtLogo.vue still absent (not opt B)" check_N1_component_still_absent
run N2 "N2 [guard] — jest.config.js gained no ignore/match (not opt C)" check_N2_jest_config_not_weakened
run N3 "N3 [guard] — package.json \"test\" is still plain jest"         check_N3_test_script_unfiltered
echo

if [ -n "$JEST_STATUS" ] && [ "$JEST_STATUS" != "no-node" ] && [ "$JEST_STATUS" != "no-jest" ]; then
    echo "  jest exit=$JEST_STATUS | $(grep -E '^Test Suites:' "$JEST_LOG" | tail -1)"
    echo "                        | $(grep -E '^Tests:' "$JEST_LOG" | tail -1)"
elif [ "$JEST_STATUS" = "no-node" ]; then
    echo "  NOTE: node not found (tried PATH and ~/.nvm) — B3/B4 failed closed."
elif [ "$JEST_STATUS" = "no-jest" ]; then
    echo "  NOTE: node_modules/.bin/jest missing — run 'yarn install'. B3/B4 failed closed."
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
