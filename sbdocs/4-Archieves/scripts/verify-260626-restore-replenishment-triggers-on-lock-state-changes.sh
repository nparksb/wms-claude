#!/usr/bin/env bash
# verify-260626-restore-replenishment-triggers-on-lock-state-changes.sh
# Machine-checkable acceptance for:
#   "Restore three replenishment-maintenance triggers on lock-state changes in StockunitService"
#
# Run from the v1/wms-api project root (default below); override with PROJECT_ROOT=...
# for the release checkout when porting (helper sits at line 623, not 595, on release —
# so this script greps by method-body line range computed at runtime, not by hard-coded lines).
#
#   $ bash sbdocs/9-System/scripts/verify-260626-restore-replenishment-triggers-on-lock-state-changes.sh
#
# Exit 0 iff all checks pass.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v1/wms-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

SVC="src/main/java/net/aim_ai/wms/service/StockunitService.java"

PASS=0
FAIL=0
SKIP=0

# run <id> <description> <command...>
run() {
    local id=$1; local desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    local id=$1; local desc=$2; local reason=$3
    printf "  SKIP  %-10s  %s  (%s)\n" "$id" "$desc" "$reason"; SKIP=$((SKIP+1))
}

# --- assertion helpers ---
file_contains() { grep -qE "$1" "$2"; }
file_contains_n_times() {
    local pattern=$1 file=$2 n=$3 count
    count=$(grep -cE "$pattern" "$file" 2>/dev/null || echo 0)
    [ "$count" -ge "$n" ]
}
file_not_contains() { ! grep -qE "$1" "$2"; }

mvn_test_passes() {
    local test_class=$1
    # This box/CI needs the SDKMAN-managed JDK8 + maven on PATH (mvn is not on the
    # default PATH). Source it if present so the gate is self-contained.
    if ! command -v mvn >/dev/null 2>&1 && [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]; then
        # sdkman-init.sh is not `set -u`-clean (references unset vars), so relax it
        # around the source or it aborts this whole script before printing a result.
        set +u
        # shellcheck disable=SC1091
        source "$HOME/.sdkman/bin/sdkman-init.sh" >/dev/null 2>&1
        set -u
    fi
    # Use maven's exit code (0 = all selected tests passed). Do NOT grep -q output —
    # `-q` suppresses the "BUILD SUCCESS" / "Tests run" lines, which would make a
    # passing run look like a failure.
    mvn test -Dtest="$test_class" -DfailIfNoTests=false -Dmaven.javadoc.skip=true -Djacoco.skip=true >/dev/null 2>&1
}

# The literal restored call. Note the helper DEFINITION uses the parameter name
# `itemDataId` (not `stockUnit.getItemdataId()`), so it never matches this regex —
# only true call-sites do.
TRIGGER='triggerReplenishmentMaintenance\(stockUnit\.getItemdataId\(\)\)'

# trigger_in_method <method-name> : true iff the literal trigger call appears
# between this method's signature and the next method's signature. Branch-portable —
# does NOT depend on absolute line numbers, so the same script works on develop
# (helper at 595) and release (helper at 623).
#
# NOTE: deliberately avoids ERE interval quantifiers like `{4}` in the awk
# patterns — the default awk on many of our boxes/CI images is mawk, which
# panics on intervals ("REcompile() - panic"). The method-end boundary is
# matched with four LITERAL spaces (the file's method-signature indent) instead.
trigger_in_method() {
    local method=$1
    awk -v m="$method" -v trig="$TRIGGER" '
        $0 ~ ("(public|private|protected).*[ \t]" m "\\(") { inb=1; next }
        inb && /^    (public|private|protected) / { inb=0 }
        inb && $0 ~ trig { found=1 }
        END { exit (found ? 0 : 1) }
    ' "$SVC"
}
not_trigger_in_method() { ! trigger_in_method "$1"; }

# --- checks ---

# Whole-file count: exactly 3 call sites.
check_count_three() { file_contains_n_times "$TRIGGER" "$SVC" 3; }

check_setLockOnHold_triggers()    { trigger_in_method "setLockOnHold"; }
check_setLockDamaged_triggers()   { trigger_in_method "setLockDamaged"; }
check_removeLock_triggers()       { trigger_in_method "removeLock"; }

check_transferStock_no_trigger()        { not_trigger_in_method "transferStock"; }
check_adjustReservedAmount_no_trigger() { not_trigger_in_method "adjustReservedAmount"; }
check_adjustAmount_no_trigger()         { not_trigger_in_method "adjustAmount"; }

# Helper still exists (becomes live, not deleted).
check_helper_present() {
    file_contains 'private void triggerReplenishmentMaintenance\(Long itemDataId\)' "$SVC"
}

echo
echo "verify-260626-restore-replenishment-triggers — running acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# Positive — the 3 restore sites
run P-count   "Exactly 3 trigger call sites in StockunitService.java" check_count_three
run P-hold    "setLockOnHold restores the trigger"                    check_setLockOnHold_triggers
run P-damaged "setLockDamaged restores the trigger"                   check_setLockDamaged_triggers
run P-unlock  "removeLock restores the trigger"                       check_removeLock_triggers
run P-helper  "triggerReplenishmentMaintenance helper still present"  check_helper_present
echo

# Negative — the 2 keep-off sites + the deferred one
run N-split   "transferStock does NOT trigger (SBDEV-2033 bug boundary)"        check_transferStock_no_trigger
run N-resv    "adjustReservedAmount does NOT trigger (SBDEV-2033 bug boundary)" check_adjustReservedAmount_no_trigger
run N-adjamt  "adjustAmount does NOT trigger (deferred / out of scope)"         check_adjustAmount_no_trigger
echo

# Behavior — this plan's 5 tests only. Scoped to the plan's methods on purpose: the full
# StockunitServiceUnitTest class has a PRE-EXISTING, unrelated failure on develop
# (transferStock_toNewLocation_nonFlowbin_entireStockUnit_noFla_movesUnitload NPEs at :1138 —
# the 260624 stock-unit-history work added stockrecordService to the transfer path and that
# older test doesn't stub it; confirmed failing with this plan's changes stashed). Full
# `mvn verify` is also deliberately avoided (v1 IT blocker SBDEV-2384).
PLAN_TESTS="StockunitServiceUnitTest#setLockOnHold_triggersReplenishmentMaintenance+setLockDamaged_triggersReplenishmentMaintenance+removeLock_triggersReplenishmentMaintenance+removeLock_qualityFault_triggersReplenishmentMaintenance+transferStock_doesNotTriggerReplenishmentMaintenance+adjustReservedAmount_doesNotTriggerReplenishmentMaintenance"
run T-unit    "This plan's 6 StockunitServiceUnitTest tests pass" mvn_test_passes "$PLAN_TESTS"
echo

echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
