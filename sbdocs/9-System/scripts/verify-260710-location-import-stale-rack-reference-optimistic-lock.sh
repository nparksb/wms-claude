#!/usr/bin/env bash
# verify-260710-location-import-stale-rack-reference-optimistic-lock.sh
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/260710-location-import-stale-rack-reference-optimistic-lock.md
#
# Run:
#   $ bash sbdocs/9-System/scripts/verify-260710-location-import-stale-rack-reference-optimistic-lock.sh
#   $ SKIP_MVN=1 bash ...   # code-shape checks only (skip the unit-test run)
#
# Exit code 0 only when every check passes. Paste the output in the
# end-of-task report — a DONE claim with FAIL lines is not accepted.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

CTRL="src/main/java/net/aim_ai/wms/controller/FileImportController.java"
TEST="src/test/java/net/aim_ai/wms/unit/controller/FileImportControllerUnitTest.java"

PASS=0
FAIL=0
SKIP=0

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

skip() {
    local id=$1
    local desc=$2
    local reason=$3
    printf "  SKIP  %-8s  %s  (%s)\n" "$id" "$desc" "$reason"
    SKIP=$((SKIP+1))
}

file_contains() { grep -qE "$1" "$2"; }
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }
file_contains_n_times() {
    local pattern=$1 file=$2 n=$3
    local count
    count=$(grep -cE "$pattern" "$file" 2>/dev/null || echo 0)
    [ "$count" -ge "$n" ]
}
file_contains_exactly_n() {
    local pattern=$1 file=$2 n=$3
    local count
    count=$(grep -cE "$pattern" "$file" 2>/dev/null || echo 0)
    [ "$count" -eq "$n" ]
}
mvn_test_passes() {
    local test_class=$1
    # no -q: maven quiet mode suppresses the INFO-level "BUILD SUCCESS" line the grep needs
    mvn test -Dtest="$test_class" -DfailIfNoTests=false 2>&1 | grep -qE "BUILD SUCCESS"
}

# === Fix A — rackMap refreshed after the else-branch re-save =================

# Positive: the else-branch save is immediately followed by a rackMap.put
check_A_cache_refresh_after_resave() {
    grep -E -A2 'rack = locationRackRepository\.save\(rack\);' "$CTRL" \
        | grep -qE 'rackMap\.put\(locationDto\.getRackName\(\), rack\);'
}

# Positive: rackMap.put(getRackName(), rack) now appears >= 3 times
# (fetch path :210 + create path :251 + the new else-branch refresh)
check_A_put_count() {
    file_contains_n_times 'rackMap\.put\(locationDto\.getRackName\(\), rack\);' "$CTRL" 3
}

# === Fix B — rackRowMap GET keyed by rack-row name ===========================

check_B_get_by_rackrow_name() {
    file_contains 'rackRowMap\.get\(locationDto\.getRackRowName\(\)\)' "$CTRL"
}

# Negative: the old wrong-key GET is gone
check_B_old_key_gone() {
    file_not_contains 'rackRowMap\.get\(locationDto\.getRackName\(\)' "$CTRL"
}

# === Fix C — copy-paste log strings corrected ================================

check_C_locations_log() {
    file_contains '"import locations called with \{\}"' "$CTRL"
}

check_C_skus_log() {
    file_contains '"import skus called with \{\}"' "$CTRL"
}

# Exactly one remaining "import inbound bol called with" (importInboundBols only)
check_C_inbound_bol_log_unique() {
    file_contains_exactly_n '"import inbound bol called with \{\}"' "$CTRL" 1
}

# === Tests (§8 of the plan) ==================================================

check_T_test_stale_cache_exists() {
    file_contains 'importLocations_multipleRowsSameRack_reSavesLatestInstanceNotStaleCache' "$TEST"
}

check_T_test_no_optimistic_lock_exists() {
    file_contains 'importLocations_reusedStaleRack_doesNotPropagateOptimisticLock' "$TEST"
}

check_T_test_rackrow_cache_hit_exists() {
    file_contains 'importLocations_rackRowCacheHitByRackRowName' "$TEST"
}

# =============================================================================

echo
echo "verify-260710-location-import-stale-rack-reference-optimistic-lock — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

run A1 "Fix A — else-branch save immediately followed by rackMap.put refresh" check_A_cache_refresh_after_resave
run A2 "Fix A — rackMap.put(getRackName(), rack) appears >= 3 times (fetch + create + else)" check_A_put_count
echo
run B1 "Fix B — rackRowMap.get keyed by getRackRowName()" check_B_get_by_rackrow_name
run B2 "Fix B — old wrong-key rackRowMap.get(getRackName()) is gone" check_B_old_key_gone
echo
run C1 "Fix C — importLocations logs 'import locations called with {}'" check_C_locations_log
run C2 "Fix C — importSkus logs 'import skus called with {}'" check_C_skus_log
run C3 "Fix C — 'import inbound bol called with {}' remains only in importInboundBols" check_C_inbound_bol_log_unique
echo
run T1 "Tests — stale-cache ArgumentCaptor test exists" check_T_test_stale_cache_exists
run T2 "Tests — no-optimistic-lock-propagation test exists" check_T_test_no_optimistic_lock_exists
run T3 "Tests — rack-row cache-hit test exists" check_T_test_rackrow_cache_hit_exists
echo

if [ "${SKIP_MVN:-0}" = "1" ]; then
    skip M1 "mvn test -Dtest=FileImportControllerUnitTest passes" "SKIP_MVN=1"
else
    run M1 "mvn test -Dtest=FileImportControllerUnitTest passes" mvn_test_passes FileImportControllerUnitTest
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
