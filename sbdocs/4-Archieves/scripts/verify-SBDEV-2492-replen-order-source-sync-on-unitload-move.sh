#!/usr/bin/env bash
# verify-SBDEV-2492-replen-order-source-sync-on-unitload-move.sh  (V2 / wms2-api)
#
# Machine-checkable acceptance for SBDEV-2492 (V2) — "Replenishment-Order Source
# Not Synced on Unit-Load Move", ported to v2/wms2-api.
# Plan: sbdocs/1-Projects/wms2/plan/SBDEV-2492-replen-order-source-sync-on-unitload-move.md
#
# REWRITTEN from the v1 script: PROJECT_ROOT now defaults to v2/wms2-api; the
# DROPPED Decision-5 controller-wrap checks (OptimisticLockRetry call sites) are
# DELETED and replaced by a re-introduction GUARD; Option-B (findByIdForUpdate)
# and NEW-1 (setLockOnHold tenant @Transactional) checks are ADDED; the
# Testcontainers ITs are SKIPPED (SBDEV-2217), not run.
#
# Run before the first change (FAIL baseline) and after every implementation
# pass. Final acceptance: "Result: N pass, 0 fail". Content-level greps at the
# call-site — filename-level checks are not sufficient.
#
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2492-replen-order-source-sync-on-unitload-move.sh
#
# Exit code is 0 only when every check passes.
#
# Depends on SBDEV-2481 being on the branch first (the hook lives inside its
# BLOCK_REALIGN block in processTransfer).

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

SRC="src/main/java/net/aim_ai/wms"
SYNC_SVC="$SRC/service/ReplenishmentOrderSourceSyncService.java"
UBS="$SRC/service/UnitloadBusinessService.java"
MMUS="$SRC/service/mobile/MobileMoveUnitloadService.java"
ROS="$SRC/service/ReplenishorderService.java"
SUS="$SRC/service/StockunitService.java"

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

# (a) hook present in the BLOCK_REALIGN loop of processTransfer
check_a_hook() {
    grep -q "replenishmentOrderSourceSyncService.syncForMovedStockUnit" "$UBS"
}

# (b) new service re-points the full triple
check_b_triple_loc()  { grep -q "setRequestedlocationId" "$SYNC_SVC"; }
check_b_triple_rack() { grep -q "setRequestedrackId"     "$SYNC_SVC"; }
check_b_triple_name() { grep -q "setSourcelocationname"  "$SYNC_SVC"; }

# (c) >= STARTED block present in the new service
check_c_started_block() {
    grep -Eq "getState\(\)\s*>=\s*WmsConstants\.State\.STARTED" "$SYNC_SVC"
}

# (d) Option B: new service uses findByIdForUpdate to serialize with the cron
check_d_pessimistic() { grep -q "findByIdForUpdate" "$SYNC_SVC"; }

# (e) NEW-1: the @Transactional annotation must sit on the line IMMEDIATELY
#     preceding the setLockOnHold declaration (proximity check — a file-level
#     grep would pass vacuously off the sibling methods that already carry it
#     at :149/:446). The reflection-level assertion is AC13 /
#     StockunitServiceLockOnHoldTxTest.
check_e_new1_tx() {
    awk '
      /@Transactional\(value = "tenantTransactionManager"/ { armed=1; next }
      /public .* setLockOnHold\(/ { if (armed) { found=1 }; armed=0; next }
      { armed=0 }
      END { exit (found ? 0 : 1) }
    ' "$SUS"
}

# (f) Fix C: redirectSource now sets sourcelocationname
check_f_redirect_name() { grep -q "setSourcelocationname" "$ROS"; }

# ---- NEGATIVE guards -------------------------------------------------------

# (g) Fix B: checkReservedStock no longer cancels the replen
check_g_no_cancel() {
    ! grep -q "cancelReplenishmentOrder" "$MMUS"
}

# (h) new service has no @Retryable (dead-annotation guard)
check_h_no_retryable() {
    ! grep -q "@Retryable" "$SYNC_SVC"
}

# (i) re-introduction guard: the move services/controllers must NOT inject
#     OptimisticLockRetry (this is what OptimisticLockRetryScopeTest pins —
#     the CLASS still exists at util/OptimisticLockRetry.java and is used by
#     MobilePalletizingService, but it must not be wired into the move path).
check_i_no_olr_inject() {
    ! grep -q "OptimisticLockRetry" "$UBS" \
      && ! grep -q "OptimisticLockRetry" "$MMUS" \
      && ! grep -q "OptimisticLockRetry" "$SYNC_SVC"
}

# (j) processTransfer must not reference stockrecordService (don't regress 260624)
check_j_no_stockrecord() {
    ! grep -q "stockrecordService" "$UBS"
}

echo "== SBDEV-2492 (V2) acceptance =="
echo "PROJECT_ROOT=$PROJECT_ROOT"
echo

run a   "hook: syncForMovedStockUnit called in UnitloadBusinessService BLOCK_REALIGN" check_a_hook
run b1  "new service sets requestedlocationId"  check_b_triple_loc
run b2  "new service sets requestedrackId"      check_b_triple_rack
run b3  "new service sets sourcelocationname"   check_b_triple_name
run c   "new service blocks state >= STARTED"   check_c_started_block
run d   "Option B: new service uses findByIdForUpdate" check_d_pessimistic
run e   "NEW-1: setLockOnHold carries tenant @Transactional" check_e_new1_tx
run f   "Fix C: redirectSource sets sourcelocationname" check_f_redirect_name
run g   "NEG: checkReservedStock no longer cancels replen" check_g_no_cancel
run h   "NEG: new service has no @Retryable" check_h_no_retryable
run i   "NEG: OptimisticLockRetry not injected into move path" check_i_no_olr_inject
run j   "NEG: processTransfer does not reference stockrecordService" check_j_no_stockrecord

# ---- Testcontainers ITs: SKIP (SBDEV-2217) ---------------------------------
skip T-IT  "ReplenishmentOrderSourceSyncIT"     "SBDEV-2217: v2 Testcontainers lane cannot boot; IT @Disabled"
skip T-CIT "MoveCronConcurrencyIT (Option B)"   "SBDEV-2217: v2 Testcontainers lane cannot boot; IT @Disabled"

# ---- Behavior: unit tests (the §8 classes only) ----------------------------
if [ "${RUN_MVN:-0}" = "1" ]; then
    run U-SYNC  "ReplenishmentOrderSourceSyncServiceTest (mvn)" \
        mvn -q test -Dtest=ReplenishmentOrderSourceSyncServiceTest
    run U-UBS   "UnitloadBusinessServiceReplenSyncTest (mvn)" \
        mvn -q test -Dtest=UnitloadBusinessServiceReplenSyncTest
    run U-MMUS  "MobileMoveUnitloadServiceUnitTest (mvn)" \
        mvn -q test -Dtest=MobileMoveUnitloadServiceUnitTest
    run U-ROS   "ReplenishorderServiceUnitTest (mvn)" \
        mvn -q test -Dtest=ReplenishorderServiceUnitTest
    run U-HOLD  "StockunitServiceLockOnHoldTxTest (mvn, Phase 0)" \
        mvn -q test -Dtest=StockunitServiceLockOnHoldTxTest
else
    skip U-SYNC "ReplenishmentOrderSourceSyncServiceTest" "set RUN_MVN=1 to run unit tests"
    skip U-UBS  "UnitloadBusinessServiceReplenSyncTest"   "set RUN_MVN=1 to run unit tests"
    skip U-MMUS "MobileMoveUnitloadServiceUnitTest"       "set RUN_MVN=1 to run unit tests"
    skip U-ROS  "ReplenishorderServiceUnitTest"           "set RUN_MVN=1 to run unit tests"
    skip U-HOLD "StockunitServiceLockOnHoldTxTest"        "set RUN_MVN=1 to run unit tests"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
