#!/usr/bin/env bash
# verify-SBDEV-2481-stale-pick-line-realignment-on-stock-move.sh
#
# Machine-checkable acceptance for SBDEV-2481 — "Stale Pick-Line References
# Survive Stock / Unit-Load Moves".
# Plan: sbdocs/1-Projects/wms1/plan/SBDEV-2481-stale-pick-line-realignment-on-stock-move.md
#
# Run before the first change (FAIL baseline) and after every implementation
# pass. Final acceptance: "Result: N pass, 0 fail". Paste that line in the
# end-of-task report — filename-level checks are not sufficient; these are
# content-level greps at the call-site.
#
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2481-stale-pick-line-realignment-on-stock-move.sh
#
# Exit code is 0 only when every check passes.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v1/wms-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() { printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

file_exists()       { test -f "$1"; }
file_contains()     { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { ! grep -qE "$1" "$2" 2>/dev/null; }
# Like file_not_contains but ignores Java comment lines (// , * , /* , */) so an
# explanatory doc-comment that NAMES a forbidden symbol doesn't trip a negative check.
code_not_contains() { ! grep -vE '^[[:space:]]*(\*|//|/\*|\*/)' "$2" 2>/dev/null | grep -qE "$1"; }
code_contains()     { grep -vE '^[[:space:]]*(\*|//|/\*|\*/)' "$2" 2>/dev/null | grep -qE "$1"; }
# Multi-line variant — perl -0777 so the regex can span newlines.
# Require the file to exist first: perl's implicit loop exits 0 on a missing
# file, which would make a POSITIVE check pass vacuously before the file is created.
file_contains_ml()  { test -f "$2" && PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null; }

SVC=src/main/java/net/aim_ai/wms/service
MOB=$SVC/mobile
REPO=src/main/java/net/aim_ai/wms/repo/jpa

PPOS_REPO=$REPO/PickingorderPositionRepository.java
REALIGN=$SVC/PickLineRealignmentService.java
CLASSIFIER=$SVC/PickLineActivityCodeClassifier.java
ULB=$SVC/UnitloadBusinessService.java
SUB=$SVC/StockunitBusinessService.java
FLA=$SVC/FixLocationAssignmentService.java
MMS=$MOB/MobileMoveStockService.java

echo
echo "verify-SBDEV-2481 — stale pick-line realignment on stock move"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# --- P0 — detector SQL typo fix (gates everything) ----------------------------
run P0a "P0 — detector SQL has '=' join: pickfromstockunit_id = stockunit.id" \
    file_contains 'pickfromstockunit_id[[:space:]]*=[[:space:]]*stockunit\.id' "$PPOS_REPO"
run P0b "P0 — broken missing-'=' join 'pickfromstockunit_id stockunit.id' is gone" \
    file_not_contains 'pickfromstockunit_id[[:space:]]+stockunit\.id' "$PPOS_REPO"
run P0c "P0 — detector SQL has '=' join: unitload_id = unitLoad.id (no missing '=')" \
    file_not_contains 'stockUnit\.unitload_id[[:space:]]+unitLoad\.id' "$PPOS_REPO"

echo

# --- P1 — activityCode taxonomy (#1) ------------------------------------------
run P1a "P1 — PickLineActivityCodeClassifier present" \
    file_exists "$CLASSIFIER"
run P1b "P1 — BLOCK_REALIGN_CODES set declared" \
    file_contains 'BLOCK_REALIGN_CODES' "$CLASSIFIER"
run P1c "P1 — PASS_THROUGH_CODES set declared" \
    file_contains 'PASS_THROUGH_CODES' "$CLASSIFIER"
# CODE_MANUAL_SPLIT must be classified PASS_THROUGH. The set is built via a `pass.add(...)` /
# `block.add(...)` static initializer, so assert: it IS referenced, and it is NOT added to the
# block (BLOCK_REALIGN) builder. The behavioral guarantee is the classifier unit test (T-CLS).
run P1d  "P1 — CODE_MANUAL_SPLIT referenced in classifier" \
    code_contains 'CODE_MANUAL_SPLIT' "$CLASSIFIER"
run P1d2 "P1 — CODE_MANUAL_SPLIT not added to the BLOCK_REALIGN builder" \
    code_not_contains 'block\.add\([^)]*CODE_MANUAL_SPLIT' "$CLASSIFIER"
run P1e "P1 — unknown code fails open with a WARN log" \
    file_contains 'LOG\.warn' "$CLASSIFIER"

echo

# --- P1 — PickLineRealignmentService, ACYCLIC BY CONSTRUCTION (#A / R-6) -------
run P1f "P1 — PickLineRealignmentService present" \
    file_exists "$REALIGN"
run P1g "P1 — realign uses repository.save (inline rewrite)" \
    file_contains 'pickingorderPositionRepository\.save' "$REALIGN"
run P1h "P1 — realign uses findByPickfromstockunitId (correct finder)" \
    file_contains 'findByPickfromstockunitId' "$REALIGN"
# Cycle guards: the service must NOT inject the business services or PickingorderPositionService.
# Uses code_not_contains so an explanatory doc-comment naming these symbols doesn't false-fail.
run P1i "P1(cycle) — does NOT inject StockunitBusinessService" \
    code_not_contains 'StockunitBusinessService' "$REALIGN"
run P1j "P1(cycle) — does NOT inject UnitloadBusinessService" \
    code_not_contains 'UnitloadBusinessService' "$REALIGN"
run P1k "P1(cycle) — does NOT inject PickingorderPositionService (fixPickingPosition stays in ops flow)" \
    code_not_contains 'PickingorderPositionService' "$REALIGN"
# I-1: realign must never rewrite the stock-unit FK (require the call form, ignore comments).
run P1l "I-1 — realign path does NOT call setPickfromstockunitId(" \
    code_not_contains 'setPickfromstockunitId\(' "$REALIGN"
run P1m "P1 — exact block message present" \
    file_contains 'currently tied to active picking work' "$REALIGN"

echo

# --- P1 — Hook A / Hook B wired at the choke points ---------------------------
run HAa "Hook A — UnitloadBusinessService references PickLineRealignmentService" \
    file_contains 'pickLineRealignmentService' "$ULB"
run HAb "Hook A — classify() gate present in UnitloadBusinessService" \
    file_contains 'classify\(' "$ULB"
run HBa "Hook B — StockunitBusinessService references PickLineRealignmentService" \
    file_contains 'pickLineRealignmentService' "$SUB"
run HBb "Hook B — classify() gate present in StockunitBusinessService" \
    file_contains 'classify\(' "$SUB"

echo

# --- P2 — fixed-assignment move (primary regression) --------------------------
run P2a "P2 — move() is @Transactional" \
    file_contains_ml '@Transactional[^)]*\)?[[:space:]]*public[[:space:]]+void[[:space:]]+move\(' "$FLA"
run P2b "P2 — broken finder findByCustomerorderpositionId(oldLocation.getId()) is GONE" \
    file_not_contains 'findByCustomerorderpositionId\(oldLocation\.getId\(\)\)' "$FLA"
run P2c "P2 — wrong-field write setPickfromunitloadlabel(destination.getName()) is GONE" \
    file_not_contains 'setPickfromunitloadlabel\(destination\.getName\(\)\)' "$FLA"

echo

# --- P4 — mobile move-stock atomicity (#3 / AC-2) -----------------------------
run P4a "P4 — MobileMoveStockService.selectDestination is @Transactional" \
    file_contains_ml '@Transactional[^)]*\)?[[:space:]]*(public[[:space:]]+)?[A-Za-z0-9_<>,.[:space:]]*[[:space:]]selectDestination\(' "$MMS"

echo

# --- Targeted tests (code-shape greps prove the call exists; tests prove it works) ---
# Unit tests run under surefire (mvn test). Skip javadoc/jacoco/checkstyle for speed.
mvn_test_passes() {
    mvn test -Dtest="$1" -DfailIfNoTests=false \
        -Dmaven.javadoc.skip=true -Djacoco.skip=true -Dcheckstyle.skip=true >/dev/null 2>&1
}
# Integration tests (*IT) run under FAILSAFE (mvn verify), NOT surefire — running them via
# `mvn test` mishandles the Testcontainers/Spring lifecycle. Suppress surefire (no matching
# unit test) so pre-existing unit failures don't abort before failsafe; rely on failsafe:verify
# exit code. The daemon needs api.version >= 1.40.
it_test_passes() {
    # Clear stale reused postgres:12 testcontainers — a leftover container in a bad state
    # makes the @SpringBootTest IT flake (documented remedy for v1 ITs).
    docker rm -f $(docker ps -aq --filter ancestor=postgres:12) >/dev/null 2>&1 || true
    mvn verify -Dit.test="$1" -Dtest=__NoSuchSurefireTest__ -DfailIfNoTests=false \
        -DargLine="-Dapi.version=1.41" \
        -Dmaven.javadoc.skip=true -Djacoco.skip=true -Dcheckstyle.skip=true >/dev/null 2>&1
}

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T-CLS  "T — PickLineActivityCodeClassifierUnitTest passes" mvn_test_passes PickLineActivityCodeClassifierUnitTest
    run T-SVC  "T — PickLineRealignmentServiceUnitTest passes"     mvn_test_passes PickLineRealignmentServiceUnitTest
    run T-FLA  "T — FixLocationAssignmentServiceUnitTest passes"   mvn_test_passes FixLocationAssignmentServiceUnitTest
    run T-IT   "T — PickLineRealignmentIT passes (Testcontainers, failsafe)" it_test_passes PickLineRealignmentIT
else
    skip T-mvn "Targeted test runs" "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
