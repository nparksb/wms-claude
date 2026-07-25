#!/usr/bin/env bash
# verify-SBDEV-2575-multi-unitload-replen-requires-new-self-deadlock.sh
#
# Machine-checkable acceptance for the multi-UL replenish REQUIRES_NEW self-deadlock fix.
# Plan: sbdocs/1-Projects/wms2/plan/SBDEV-2575-multi-unitload-replen-requires-new-self-deadlock.md
#
#   $ PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
#       bash sbdocs/9-System/scripts/verify-SBDEV-2575-multi-unitload-replen-requires-new-self-deadlock.sh
#
# Exit 0 iff all checks pass. Paste the final "Result:" line in the end-of-task report.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}
skip() { printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

file_contains()      { grep -qE "$1" "$2"; }
file_not_contains()  { ! grep -qE "$1" "$2"; }
# Count occurrences of a pattern in a file and require at least N.
file_contains_n_times() {
    local pattern=$1 file=$2 min=$3
    local count
    count=$(grep -cE "$pattern" "$file")
    [ "$count" -ge "$min" ]
}
mvn_test_passes() {
    # NOTE: -q suppresses the "BUILD SUCCESS"/"Tests run" banner on success, so grepping combined
    # stdout+stderr for that text is unreliable — rely on mvn's own exit code instead.
    mvn -o test -Dtest="$1" -DfailIfNoTests=false -q >/dev/null 2>&1
}

RGS=src/main/java/net/aim_ai/wms/service/ReplenishGeneratorService.java
MRS=src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java
SUR=src/main/java/net/aim_ai/wms/repo/jpa/StockunitRepository.java

# --- Fix A: createOrderFromTemplate joins the caller tx (REQUIRED, not REQUIRES_NEW) ---
# POSITIVE: the createOrderFromTemplate method exists and is @Transactional on tenant TM.
check_A_method_present() { file_contains 'public Replenishorder createOrderFromTemplate\(' "$RGS"; }
# NEGATIVE: the annotation immediately preceding createOrderFromTemplate must no longer be REQUIRES_NEW.
# We assert the *specific* prior REQUIRES_NEW+rollbackFor=FacadeException.class line is gone from the file.
check_A_no_requires_new_facade_only() {
    file_not_contains 'propagation = Propagation.REQUIRES_NEW, rollbackFor = FacadeException.class\)' "$RGS"
}
# POSITIVE: the two SIBLING REQUIRES_NEW methods (calculateOrder / refillSingleFixedLocation) are UNTOUCHED
# — the file must still contain the {Facade,Business} REQUIRES_NEW variant they use (row 6/7 exclusion).
check_A_siblings_preserved() {
    file_contains 'propagation = Propagation.REQUIRES_NEW, rollbackFor = \{FacadeException.class, BusinessException.class\}' "$RGS"
}

# --- Fix A.2: explicit flush ordering (the critical part — prevents 23505 under single tx) ---
# POSITIVE: fulfillMultipleUnitLoads flushes after each state=700 transition (>=2 flushes in MRS).
check_A2_mrs_flush()  { file_contains_n_times 'replenishorderRepository\.flush\(\)' "$MRS" 2; }
# POSITIVE: createOrderFromTemplate isolates its child INSERT with a flush — RGS gains a 2nd flush
# (existing one is calculateOrder:255).
check_A2_rgs_flush()  { file_contains_n_times 'replenishorderRepository\.flush\(\)' "$RGS" 2; }

# --- Fix B: entityManager.refresh workaround removed from the multi-UL loop ---
check_B_refresh_gone()   { file_not_contains 'entityManager\.refresh\(inst\.stock\)' "$MRS"; }
check_B_loop_intact()    { file_contains 'createOrderFromTemplate\(' "$MRS"; }

# --- Fix D: refill/recalc moved to a post-commit wrapper (transactional core extracted) ---
check_D_tx_core()  { file_contains 'fulfillMultipleUnitLoadsTx' "$MRS"; }

# --- Fix C: lock.timeout hint on Stockunit.findByIdForUpdate ---
check_C_lock_timeout()   { file_contains 'jakarta\.persistence\.lock\.timeout' "$SUR"; }
check_C_still_pessimistic() { file_contains 'LockModeType\.PESSIMISTIC_WRITE' "$SUR"; }

echo
echo "verify-SBDEV-2575 — multi-UL replenish REQUIRES_NEW self-deadlock"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

run A1  "Fix A.1 — createOrderFromTemplate present"               check_A_method_present
run A2  "Fix A.1 — REQUIRES_NEW(FacadeException-only) removed"    check_A_no_requires_new_facade_only
run A3  "Fix A.1 — sibling REQUIRES_NEW methods preserved"        check_A_siblings_preserved
run A4  "Fix A.2 — MobileReplenishService flushes >=2x (ordering)" check_A2_mrs_flush
run A5  "Fix A.2 — createOrderFromTemplate flush isolates INSERT"  check_A2_rgs_flush
echo
run B1  "Fix B — entityManager.refresh(inst.stock) removed"       check_B_refresh_gone
run B2  "Fix B — multi-UL loop still calls createOrderFromTemplate" check_B_loop_intact
echo
run C1  "Fix C — jakarta lock.timeout hint added"                 check_C_lock_timeout
run C2  "Fix C — PESSIMISTIC_WRITE lock retained"                 check_C_still_pessimistic
echo
run D1  "Fix D — transactional core (fulfillMultipleUnitLoadsTx) extracted" check_D_tx_core
echo

# Behavioural proof (code-shape greps prove the call exists, not that it works).
if command -v mvn >/dev/null 2>&1; then
    run T1 "unit — ReplenishGeneratorServiceUnitTest passes"  mvn_test_passes ReplenishGeneratorServiceUnitTest
    run T2 "unit — MobileReplenishServiceUnitTest passes"     mvn_test_passes MobileReplenishServiceUnitTest
else
    skip T1 "ReplenishGeneratorServiceUnitTest" "mvn not on PATH"
    skip T2 "MobileReplenishServiceUnitTest"    "mvn not on PATH"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
