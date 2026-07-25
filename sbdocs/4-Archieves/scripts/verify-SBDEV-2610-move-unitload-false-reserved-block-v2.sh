#!/usr/bin/env bash
# verify-SBDEV-2610-move-unitload-false-reserved-block-v2.sh
# Machine-checkable acceptance for the v2 port of SBDEV-2610 (revised after v2 critic+architect).
# Part 1 (incident) = clarify SBDEV-2492 in-progress-replen block AT BOTH THROW SITES (NEW-2);
# Part 2 (latent) = checkReservedStock honesty + orphan reconciliation via an audited admin job.
#
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2610-move-unitload-false-reserved-block-v2.sh
#
# Exit 0 iff all checks pass.

set -u
shopt -s globstar 2>/dev/null || true
PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0
run() { local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi; }
skip() { printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }
file_contains()     { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }
# any file under a set of dirs contains the regex (globstar-based, no compgen multi-pattern bug)
tree_contains() { local re=$1; shift; grep -rqlE "$re" "$@" 2>/dev/null; }
# Rely on mvn's EXIT CODE (0 = success), not on a "BUILD SUCCESS" banner — `-q` suppresses that
# banner, so grepping for it always failed even on a clean build (verify-script bug, fixed here).
mvn_compiles()    { mvn -q clean compile >/dev/null 2>&1; }
mvn_test_passes() { mvn -q test -Dtest="$1" -DfailIfNoTests=false >/dev/null 2>&1; }

SRC=src/main/java/net/aim_ai/wms/service/ReplenishmentOrderSourceSyncService.java
MNT=src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java
MMU=src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java
SVC=src/main/java/net/aim_ai/wms/service

# --- Part 1 / A1: BOTH block sites carry the replen order number (NEW-2) ---
check_A1_src_block()   { file_contains 'complete or cancel' "$SRC"; }
# order number must appear WITHIN the throw statement (context window around the message),
# not merely somewhere in the file — otherwise a big service false-passes (critic finding).
check_A1_src_ordernum(){ grep -B1 -A2 'complete or cancel' "$SRC" 2>/dev/null | grep -qE 'getNumber\(\)|replenBlockMessage|replenInProgressMessage'; }
check_A1_mnt_ordernum(){ grep -B1 -A2 'complete or cancel' "$MNT" 2>/dev/null | grep -qE 'getNumber\(\)|replenBlockMessage|replenInProgressMessage'; }
check_A1_shared_msg()  { grep -rqE 'replenBlockMessage|replenInProgressMessage' "$SVC"; }   # shared builder (preferred)

# --- Part 1 / A2: TransferInfoDto active-replen field populated in scanUnitLoad ---
check_A2_dto_field()   { grep -rqiE 'activeReplen|replenInProgress|replenNumber' src/main/java/net/aim_ai/wms/json 2>/dev/null; }

# --- Part 2 / B1: guard honesty (read-only; reuse existing repo method) ---
check_B1_pick_check()  { file_contains 'findByPickfromstockunitId' "$MMU"; }
check_B1_pick_state()  { grep -qE 'State\.(PICKED|FINISHED)|state *< *600|PICKED' "$MMU"; }
check_B1_recursion()   { file_contains 'findByCarrierunitloadId' "$MMU"; }
check_B1_marker()      { file_contains 'SBDEV-2610' "$MMU"; }
check_B1_deadend_gone(){ file_not_contains 'Reserved stock! can not move unit load' "$MMU"; }
check_B1_no_broadened(){ file_not_contains 'findOpenSourceHolder' "$MMU"; }
check_B1_tenant_tx()   { file_contains 'tenantTransactionManager' "$MMU"; }

# --- Part 2 / C1: reconciliation is an AUDITED admin job (changeReservedAmount), not raw SQL ---
check_C1_admin_recon() { tree_contains 'reconcile.*[Oo]rphan|[Oo]rphan.*[Rr]eserv' src/main/java; }
check_C1_uses_service(){ tree_contains 'changeReservedAmount' src/main/java/net/aim_ai/wms/service/**/*[Rr]econcil* 2>/dev/null \
                         || tree_contains 'SBDEV-2610.*changeReservedAmount|changeReservedAmount.*SBDEV-2610' src/main/java; }
check_C1_no_migration(){ ! compgen -G "src/main/resources/db/migration/V2.2.0[4-9]__*reconcile*orphan*" >/dev/null; } # NEW-1: NO Flyway migration

echo
echo "verify-SBDEV-2610-v2 — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo
echo "Part 1 — incident (in-progress replen block clarity, BOTH sites — NEW-2):"
run A1a "A1 — SourceSync block message present"                 check_A1_src_block
run A1b "A1 — SourceSync block names replen order"              check_A1_src_ordernum
run A1c "A1 — Maintenance block names replen order (2nd site)"  check_A1_mnt_ordernum
run A1d "A1 — shared replenBlockMessage builder (preferred)"    check_A1_shared_msg
run A2a "A2 — TransferInfoDto active-replen field added"        check_A2_dto_field
echo
echo "Part 2 — latent guard-honesty + reconciliation:"
run B1a "B1 — guard reuses findByPickfromstockunitId"           check_B1_pick_check
run B1b "B1 — active-pick state filter (<600)"                  check_B1_pick_state
run B1c "B1 — child-UL recursion preserved"                     check_B1_recursion
run B1d "B1 — stranded path marked (SBDEV-2610)"                check_B1_marker
run B1e "B1 — old dead-end throw removed"                       check_B1_deadend_gone
run B1f "B1 — broadened findOpenSourceHolder NOT added"         check_B1_no_broadened
run B1g "B1 — scanDestination still tenantTransactionManager"   check_B1_tenant_tx
run C1a "C1 — reconciliation admin construct exists"            check_C1_admin_recon
run C1b "C1 — reconciliation mutates via changeReservedAmount"  check_C1_uses_service
run C1c "C1 — NO Flyway reconciliation migration (NEW-1)"       check_C1_no_migration
echo

if command -v mvn >/dev/null 2>&1; then
    run compile "mvn clean compile (SBDEV-2217: ITs gated)" mvn_compiles
    run P2-test "MobileMoveUnitloadServiceTest passes"      mvn_test_passes MobileMoveUnitloadServiceTest
else
    skip compile "mvn clean compile" "mvn not on PATH"
    skip P2-test "MobileMoveUnitloadServiceTest" "mvn not on PATH"
fi

echo
echo "NEW-2: the >=STARTED block is thrown from BOTH ReplenishmentOrderSourceSyncService AND"
echo "       ReplenishmentOrderMaintenanceService — A1c guards the second (non-replenishable-dest) site."
echo "NEW-1: reconciliation is an audited admin job, not startup Flyway (C1c asserts no migration)."
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
