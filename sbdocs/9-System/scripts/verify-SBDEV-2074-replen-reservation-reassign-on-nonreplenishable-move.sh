#!/usr/bin/env bash
# verify-SBDEV-2074-replen-reservation-reassign-on-nonreplenishable-move.sh  (V2 / wms2-api)
#
# Machine-checkable acceptance for SBDEV-2074 (V2) — "Replenishment Reservations
# Not Released/Reassigned When Unit Load Moved to a Non-Replenishable Location".
# Plan: sbdocs/1-Projects/wms2/plan/SBDEV-2074-replen-reservation-reassign-on-nonreplenishable-move.md
#
# Follows the SBDEV-2492 script style: content-level greps at the call-site
# (filename-level checks are not sufficient), Testcontainers ITs SKIPPED
# (SBDEV-2217), unit-test mvn runs gated behind RUN_MVN=1.
#
# Run before the first change (FAIL baseline) and after every implementation
# pass. Final acceptance: "Result: N pass, 0 fail".
#
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2074-replen-reservation-reassign-on-nonreplenishable-move.sh
#
# Exit code is 0 only when every check passes.
#
# Depends on SBDEV-2481 + SBDEV-2492 already on the branch (this plan grows the
# ReplenishmentOrderSourceSyncService branch created by SBDEV-2492).

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

SRC="src/main/java/net/aim_ai/wms"
MAINT="$SRC/service/ReplenishmentOrderMaintenanceService.java"
SYNC_SVC="$SRC/service/ReplenishmentOrderSourceSyncService.java"
UBS="$SRC/service/UnitloadBusinessService.java"
SUS="$SRC/service/StockunitService.java"
# NOTE: MobileTransferOrderService is intentionally NOT checked — the former Fix C
# was dropped after verification that the transfer-order build leaves reserved stock
# at source (:404) and only moves the whole UL to a lane when reservedamount==0 (:388,:392).

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

# ---- POSITIVE checks -------------------------------------------------------

# (a) Fix A: new public reassignOrCancelForMovedStockUnit on the maintenance service
check_a_new_method() {
    grep -Eq "public\s+void\s+reassignOrCancelForMovedStockUnit\s*\(" "$MAINT"
}

# (b) Fix A/B: the destination replenishability is checked (isReplenishableDestination
#     or a direct area useforreplenish read) somewhere on the branch path.
check_b_replenishability() {
    grep -Eq "isReplenishableDestination|getUseforreplenish|useforreplenish" "$SYNC_SVC" \
      || grep -Eq "isReplenishableDestination|getUseforreplenish|useforreplenish" "$MAINT"
}

# (c) Fix A: block state >= STARTED
check_c_started_block() {
    grep -Eq "getState\(\)\s*>=\s*WmsConstants\.State\.STARTED" "$MAINT"
}

# (d) Fix A: reuses redirectSource AND cancelOrder primitives
check_d_redirect() { grep -q "redirectSource" "$MAINT"; }
check_d_cancel()   { grep -q "cancelOrder"    "$MAINT"; }

# (e) Fix B: the choke-point sync branches to reassign on a non-replenishable dest
check_e_branch_delegates() {
    grep -q "reassignOrCancelForMovedStockUnit" "$SYNC_SVC"
}

# (f) Q3/NEW-3: the new method carries the tenant @Transactional (proximity check
#     so a sibling method's annotation cannot pass it vacuously).
check_f_tenant_tx() {
    awk '
      /@Transactional\(value = "tenantTransactionManager"/ { armed=1; next }
      /public .* reassignOrCancelForMovedStockUnit\(/ { if (armed) { found=1 }; armed=0; next }
      # keep armed across a multi-line @Transactional continuation (rollbackFor/propagation/etc.)
      armed && /^[[:space:]]*(rollbackFor|propagation|readOnly|timeout|isolation|noRollbackFor)/ { next }
      { armed=0 }
      END { exit (found ? 0 : 1) }
    ' "$MAINT"
}

# ---- NEGATIVE guards -------------------------------------------------------

# (g) I-3 / SBDEV-2033 guard: the transferStock METHOD BODY must NOT re-add a
#     recalculateForItem CALL. Scope to transferStock only (recalculateForItem
#     legitimately exists in other methods, e.g. :127) and ignore comment lines
#     (the SBDEV-2033 removal note lives as a comment inside transferStock).
check_g_no_recalc() {
    ! awk '
        /public void transferStock\(/ { inm=1 }
        inm && /^[[:space:]]*(public|private|protected)[[:space:]].*\(/ && !/transferStock\(/ { inm=0 }
        inm { print }
      ' "$SUS" \
      | grep -vE '^[[:space:]]*(//|\*|/\*)' \
      | grep -q "recalculateForItem"
}

# (h) the new method must NOT be annotated with a bare @Transactional (would route
#     to the @Primary landlord TM and disable tenant-write rollback). Any
#     @Transactional immediately above the method must name tenantTransactionManager.
check_h_no_bare_tx() {
    awk '
      /@Transactional/ {
        prev=$0
        getline nxt
        if (nxt ~ /public .* reassignOrCancelForMovedStockUnit\(/) {
          if (prev !~ /tenantTransactionManager/) { bad=1 }
        }
        next
      }
      END { exit (bad ? 1 : 0) }
    ' "$MAINT"
}

echo "== SBDEV-2074 (V2) acceptance =="
echo "PROJECT_ROOT=$PROJECT_ROOT"
echo

run a   "Fix A: public reassignOrCancelForMovedStockUnit on maintenance service" check_a_new_method
run b   "Fix A/B: destination replenishability (useforreplenish) checked"        check_b_replenishability
run c   "Fix A: blocks state >= STARTED"                                          check_c_started_block
run d1  "Fix A: reuses redirectSource"                                            check_d_redirect
run d2  "Fix A: reuses cancelOrder"                                               check_d_cancel
run e   "Fix B: choke-point sync delegates to reassign on non-replen dest"        check_e_branch_delegates
run f   "Q3/NEW-3: new method carries tenant @Transactional"                      check_f_tenant_tx
run g   "NEG: transferStock body does NOT re-add recalculateForItem (SBDEV-2033)" check_g_no_recalc
run h   "NEG: new method not annotated bare @Transactional"                       check_h_no_bare_tx

# ---- Testcontainers ITs: SKIP (SBDEV-2217) ---------------------------------
skip T-IT "ReplenReassignOnNonReplenishableMoveIT" "SBDEV-2217: v2 Testcontainers lane cannot boot; IT @Disabled"

# ---- Behavior: context-load HARD GATE + unit tests (the §8 classes only) ----
if [ "${RUN_MVN:-0}" = "1" ]; then
    run G-CTX  "ReplenishReassignContextLoadTest (DI-cycle HARD GATE, mvn)" \
        mvn -q test -Dtest=ReplenishReassignContextLoadTest
    run U-MAINT "ReplenishmentOrderMaintenanceServiceReassignTest (mvn)" \
        mvn -q test -Dtest=ReplenishmentOrderMaintenanceServiceReassignTest
    run U-SYNC  "ReplenishmentOrderSourceSyncServiceBranchTest (mvn)" \
        mvn -q test -Dtest=ReplenishmentOrderSourceSyncServiceBranchTest
    run U-UBS   "UnitloadBusinessServiceReplenBranchTest (mvn)" \
        mvn -q test -Dtest=UnitloadBusinessServiceReplenBranchTest
    run U-GUARD "StockunitServiceTransferStockGuardTest (mvn, I-3)" \
        mvn -q test -Dtest=StockunitServiceTransferStockGuardTest
else
    skip G-CTX  "ReplenishReassignContextLoadTest (DI-cycle HARD GATE)" "set RUN_MVN=1 to run"
    skip U-MAINT "ReplenishmentOrderMaintenanceServiceReassignTest"     "set RUN_MVN=1 to run"
    skip U-SYNC  "ReplenishmentOrderSourceSyncServiceBranchTest"        "set RUN_MVN=1 to run"
    skip U-UBS   "UnitloadBusinessServiceReplenBranchTest"              "set RUN_MVN=1 to run"
    skip U-GUARD "StockunitServiceTransferStockGuardTest"               "set RUN_MVN=1 to run"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
