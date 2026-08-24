#!/usr/bin/env bash
# verify-SBDEV-2690-replenish-create-silent-success-on-idempotency-skip.sh
#
# Acceptance for `SBDEV-2690-replenish-create-silent-success-on-idempotency-skip.md`.
# Makes the idempotency skip observable at the admin API boundary (HTTP 409 + message),
# without changing calculateOrder's null contract for job/mobile/refill callers.
#
# Run after every implementation pass:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2690-replenish-create-silent-success-on-idempotency-skip.sh

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
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

skip() {
    printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1))
}

file_contains()        { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains()    { ! grep -qE "$1" "$2" 2>/dev/null; }
file_contains_ml()     {
    [ -f "$2" ] || return 1 PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null; }
# negative multi-line: fails (returns 1) if the pattern IS present across lines
file_not_contains_ml() { test -f "$2" && ! ( PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null ); }

SVC=src/main/java/net/aim_ai/wms/service
CTRL=src/main/java/net/aim_ai/wms/controller
EXC=src/main/java/net/aim_ai/wms/exceptions

DRE=$EXC/DuplicateReplenishmentException.java
GEN=$SVC/ReplenishGeneratorService.java
ROS=$SVC/ReplenishorderService.java
RCTRL=$CTRL/ReplenishOrderController.java

echo
echo "verify-SBDEV-2690 — replenish create silent-success fix"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# --- Fix A: new exception ----------------------------------------------------
run A1 "Fix A — DuplicateReplenishmentException.java exists" \
    test -f "$DRE"
run A2 "Fix A — extends Exception (checked), NOT BusinessException (must not be swallowed as 200/422)" \
    file_contains 'class\s+DuplicateReplenishmentException\s+extends\s+Exception' "$DRE"
run A3 "Fix A — does NOT extend BusinessException" \
    file_not_contains 'extends\s+BusinessException' "$DRE"
run A4 "Fix A — carries existingOrderNumber accessor" \
    file_contains 'getExistingOrderNumber' "$DRE"

# --- Fix B: extracted predicate, null contract preserved ---------------------
run B1 "Fix B — findBlockingPendingOrder(...) extracted in ReplenishGeneratorService" \
    file_contains 'Optional<Replenishorder>\s+findBlockingPendingOrder\s*\(' "$GEN"
run B2 "Fix B — calculateOrder still returns null on a match (contract unchanged for jobs/mobile)" \
    file_contains 'return null;' "$GEN"

# --- Fix C: service throws on skip -------------------------------------------
run C1 "Fix C — ReplenishorderService.create declares DuplicateReplenishmentException" \
    file_contains_ml 'public\s+Replenishorder\s+create\([^)]*\)\s*throws[^\{]*DuplicateReplenishmentException' "$ROS"
run C2 "Fix C — create throws DuplicateReplenishmentException" \
    file_contains 'throw\s+new\s+DuplicateReplenishmentException\(' "$ROS"
run C3 "Fix C — create calls findBlockingPendingOrder to name the blocker" \
    file_contains 'findBlockingPendingOrder\(' "$ROS"
run C4 "Fix C — old silent 'if (order == null) { return null; }' in create is gone" \
    file_not_contains_ml 'if\s*\(\s*order\s*==\s*null\s*\)\s*\{\s*return null;' "$ROS"

# --- Fix D: controller returns 409 -------------------------------------------
run D1 "Fix D — controller catches DuplicateReplenishmentException" \
    file_contains 'catch\s*\(\s*DuplicateReplenishmentException' "$RCTRL"
run D2 "Fix D — controller returns HttpStatus.CONFLICT (409) on the duplicate path" \
    file_contains_ml 'catch\s*\(\s*DuplicateReplenishmentException[^}]*HttpStatus\.CONFLICT' "$RCTRL"
run D3 "Fix D — HttpStatus imported" \
    file_contains 'import\s+org\.springframework\.http\.HttpStatus;' "$RCTRL"

# --- Tests: new methods must EXIST (static, always run) -----------------------
# Closes the "code shaped right, tests never written" false-pass: assert the new
# test methods are present, independent of whether mvn executes them.
TDIR=src/test/java/net/aim_ai/wms
GEN_TEST=$TDIR/unit/service/ReplenishGeneratorServiceUnitTest.java
ROS_TEST=$TDIR/unit/service/ReplenishorderServiceUnitTest.java
CTRL_TEST=$TDIR/unit/controller/ReplenishOrderControllerUnitTest.java

run T-SRC1 "T — new generator regression test present (calculateOrder still null / findBlockingPendingOrder)" \
    file_contains 'findBlockingPendingOrder|calculateOrder_stillReturnsNull' "$GEN_TEST"
run T-SRC2 "T — new service test present (create throws DuplicateReplenishment on skip)" \
    file_contains 'DuplicateReplenishment' "$ROS_TEST"
run T-SRC3 "T — new controller test present (create returns 409 when duplicate)" \
    file_contains 'create_returns409_whenDuplicate|CONFLICT|409' "$CTRL_TEST"

# --- Tests: actually pass (required for FINAL acceptance — RUN_MVN=1) ----------
mvn_test_passes() {
    mvn -q test -Dtest="$1" >/dev/null 2>&1
}
if [ "${RUN_MVN:-0}" = "1" ]; then
    run T-GEN  "T — ReplenishGeneratorServiceUnitTest passes"  mvn_test_passes ReplenishGeneratorServiceUnitTest
    run T-ROS  "T — ReplenishorderServiceUnitTest passes"      mvn_test_passes ReplenishorderServiceUnitTest
    run T-CTRL "T — ReplenishOrderControllerUnitTest passes"   mvn_test_passes ReplenishOrderControllerUnitTest
else
    # NOTE: final acceptance (§9b) REQUIRES RUN_MVN=1. Skipping here still leaves
    # the static T-SRC* checks above as a floor so missing tests cannot pass silently.
    skip T-GEN  "ReplenishGeneratorServiceUnitTest"  "FINAL ACCEPTANCE needs RUN_MVN=1"
    skip T-ROS  "ReplenishorderServiceUnitTest"      "FINAL ACCEPTANCE needs RUN_MVN=1"
    skip T-CTRL "ReplenishOrderControllerUnitTest"   "FINAL ACCEPTANCE needs RUN_MVN=1"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
