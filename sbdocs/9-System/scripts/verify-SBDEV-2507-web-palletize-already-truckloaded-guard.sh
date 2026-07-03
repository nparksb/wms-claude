#!/usr/bin/env bash
# verify-SBDEV-2507-web-palletize-already-truckloaded-guard.sh  (rev 2)
# Acceptance for: sbdocs/1-Projects/wms1/plan/SBDEV-2507-web-palletize-already-truckloaded-guard.md
# Run: bash sbdocs/9-System/scripts/verify-SBDEV-2507-web-palletize-already-truckloaded-guard.sh
# Exit 0 iff all checks pass.

set -u
PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v1/wms-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0
run() { local id=$1 desc=$2; shift 2; if "$@" >/dev/null 2>&1; then printf "  PASS  %-8s  %s\n" "$id" "$desc"; PASS=$((PASS+1)); else printf "  FAIL  %-8s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi; }
file_contains()     { grep -qE "$1" "$2"; }
file_contains_n()   { local n; n=$(grep -cE "$1" "$2" 2>/dev/null || echo 0); [ "$n" -ge "$3" ]; }
# Hardened: require a real test count (>=1) AND zero failures/errors, so a name typo (0 tests) FAILS
# instead of vacuously passing on BUILD SUCCESS.
# NOTE: no -q — surefire's "Tests run:" summary is INFO-level and is suppressed by -q.
mvn_test_passes()   { mvn test -Dtest="$1" -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true 2>&1 | grep -qE "Tests run: [1-9][0-9]*, Failures: 0, Errors: 0"; }

SVC="src/main/java/net/aim_ai/wms/service/BillofladingPositionService.java"
PMV="src/main/java/net/aim_ai/wms/service/ParcelMonitorViewService.java"
MOB="src/main/java/net/aim_ai/wms/service/mobile/MobilePalletizingService.java"

# --- Fix C: shared helpers exist in BillofladingPositionService ---------------
check_C_gate_helper()        { test -f "$SVC" && file_contains 'assertPalletNotAssignedToGate' "$SVC"; }
check_C_carrier_helper()     { test -f "$SVC" && file_contains 'assertParcelCarrierNotShipped' "$SVC"; }
check_C_gate_msg()           { test -f "$SVC" && file_contains 'Pallet already assigned to gate' "$SVC"; }
check_C_carrier_uses_repo()  { test -f "$SVC" && file_contains 'getBySourceUnitLoadLabelId' "$SVC"; }
# The carrier helper must read the parcel's current carrier (getCarrierunitloadId) — unique to the new code,
# so this can't pass vacuously (BillOfLadingState.CLOSED already exists elsewhere in this file).
check_C_carrier_reads_carrier(){ test -f "$SVC" && file_contains 'getCarrierunitloadId' "$SVC"; }

# --- Fix A: web palletise calls the source-parcel guard (incident vector) ------
check_A_palletise_carrier()  { file_contains 'assertParcelCarrierNotShipped' "$PMV"; }
# --- Fix B: web palletise reuse branch calls the target-pallet guard -----------
check_B_palletise_gate()     { file_contains 'assertPalletNotAssignedToGate' "$PMV"; }

# --- Fix C refactor: mobile routes all 4 sites through the helper, no inline throw
check_R_mobile_inline_gone() { test -f "$MOB" && ! grep -qE 'throw new BusinessException\("Pallet already assigned to gate' "$MOB"; }
check_R_mobile_calls_helper(){ test -f "$MOB" && file_contains_n 'assertPalletNotAssignedToGate' "$MOB" 4; }

echo
echo "verify-SBDEV-2507 (rev 2) — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo
run C1  "Fix C — assertPalletNotAssignedToGate helper present"       check_C_gate_helper
run C2  "Fix C — assertParcelCarrierNotShipped helper present"       check_C_carrier_helper
run C3  "Fix C — gate helper throws 'Pallet already assigned to gate'" check_C_gate_msg
run C4  "Fix C — carrier helper queries getBySourceUnitLoadLabelId"  check_C_carrier_uses_repo
run C5  "Fix C — carrier helper reads parcel.getCarrierunitloadId"   check_C_carrier_reads_carrier
echo
run A1  "Fix A — palletise calls assertParcelCarrierNotShipped"      check_A_palletise_carrier
run B1  "Fix B — palletise reuse calls assertPalletNotAssignedToGate" check_B_palletise_gate
echo
run R1  "Fix C refactor — mobile inline gate-guard throw removed"    check_R_mobile_inline_gone
run R2  "Fix C refactor — mobile routes >=4 sites through helper"    check_R_mobile_calls_helper
echo
run T1  "Unit — BillofladingPositionServiceUnitTest passes (>=1 test)"  mvn_test_passes BillofladingPositionServiceUnitTest
run T2  "Unit — ParcelMonitorViewServiceUnitTest passes (>=1 test)"     mvn_test_passes ParcelMonitorViewServiceUnitTest
run T3  "Unit — MobilePalletizingServiceUnitTest passes (>=1 test)"     mvn_test_passes MobilePalletizingServiceUnitTest

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
