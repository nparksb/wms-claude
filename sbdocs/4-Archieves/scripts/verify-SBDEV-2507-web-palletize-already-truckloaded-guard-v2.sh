#!/usr/bin/env bash
# verify-SBDEV-2507-web-palletize-already-truckloaded-guard-v2.sh
# Machine-checkable acceptance for SBDEV-2507 (v2 port) — palletize guards.
# Plan: sbdocs/1-Projects/wms2/plan/SBDEV-2507-web-palletize-already-truckloaded-guard.md
#
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2507-web-palletize-already-truckloaded-guard-v2.sh
#
# Baseline (pre-implementation): all C/A/B/R checks FAIL. Exit 0 iff all pass.
# Override: PROJECT_ROOT=/path/to/v2/wms2-api bash .../verify-...-v2.sh

set -u
PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0
run()  { local id=$1 desc=$2; shift 2; if "$@" >/dev/null 2>&1; then printf "  PASS  %-4s  %s\n" "$id" "$desc"; PASS=$((PASS+1)); else printf "  FAIL  %-4s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi; }
skip() { printf "  SKIP  %-4s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

SRC=src/main/java/net/aim_ai/wms
SVC=$SRC/service/BillofladingPositionService.java
WEB=$SRC/service/ParcelMonitorViewService.java
MOB=$SRC/service/mobile/MobilePalletizingService.java

# --- Positive: Fix C helpers in BillofladingPositionService ---
check_C1() { grep -qE "public void assertPalletNotAssignedToGate\(" "$SVC"; }
check_C2() { grep -qE "public void assertParcelCarrierNotShipped\(" "$SVC"; }
check_C3() { grep -qE "Pallet already assigned to gate" "$SVC"; }
check_C4() { grep -qE "getBySourceUnitLoadLabelId" "$SVC"; }
check_C5() { grep -qE "getCarrierunitloadId" "$SVC"; }
# C6 (v2-specific): ctor-injected UnitloadRepository (pins the v2 adaptation + helper home)
check_C6() { grep -qE "private final UnitloadRepository unitloadRepository" "$SVC" && grep -qE "UnitloadRepository[[:space:]]+unitloadRepository[),]" "$SVC"; }
# C7 (v2-specific): carrier helper rejects CLOSED and TRANSFER
check_C7() { grep -qE "BillOfLadingState\.CLOSED" "$SVC" && grep -qE "BillOfLadingState\.TRANSFER" "$SVC"; }

# --- Positive: Fix A + Fix B call sites in ParcelMonitorViewService ---
check_A1() { local c; c=$(grep -cE "assertParcelCarrierNotShipped\(" "$WEB" 2>/dev/null); [ "${c:-0}" -ge 2 ]; }   # both loops
check_B1() { grep -qE "assertPalletNotAssignedToGate\(" "$WEB"; }

# --- Negative: Fix C refactor in MobilePalletizingService ---
check_R1() { ! grep -qE "throw new BusinessException\(\"Pallet already assigned to gate" "$MOB"; }
check_R2() { local c; c=$(grep -cE "assertPalletNotAssignedToGate\(" "$MOB" 2>/dev/null); [ "${c:-0}" -ge 4 ]; }
# R3: the raw gate-throw appears ONLY in the shared helper (single source of truth)
check_R3() { local files; files=$(grep -rlE "throw new BusinessException\(\"Pallet already assigned to gate" "$SRC" 2>/dev/null); [ "$files" = "$SVC" ]; }

echo
echo "verify-SBDEV-2507-v2 — acceptance checks (PROJECT_ROOT=$PROJECT_ROOT)"
echo
run C1 "helper assertPalletNotAssignedToGate exists"            check_C1
run C2 "helper assertParcelCarrierNotShipped exists"            check_C2
run C3 "gate message lives in the helper"                       check_C3
run C4 "carrier helper queries getBySourceUnitLoadLabelId"      check_C4
run C5 "carrier helper reads getCarrierunitloadId"              check_C5
run C6 "ctor-injected UnitloadRepository (v2 adaptation)"       check_C6
run C7 "carrier helper rejects CLOSED and TRANSFER"             check_C7
run A1 "Fix A call in BOTH ParcelMonitorViewService loops"      check_A1
run B1 "Fix B call in reuse branch"                             check_B1
run R1 "mobile raw inline gate throw removed"                   check_R1
run R2 "mobile routes >=4 sites through the helper"             check_R2
run R3 "gate throw single-sourced in the helper file"           check_R3

echo
# Behavioral rows — enable once tests are authored (AC-1..AC-10):
# mvn_t() { mvn test -Dtest="$1" -DfailIfNoTests=false -q >/dev/null 2>&1; }
# run T1 "BillofladingPositionServiceUnitTest"  mvn_t BillofladingPositionServiceUnitTest
# run T2 "ParcelMonitorViewServiceUnitTest"     mvn_t ParcelMonitorViewServiceUnitTest
# run T3 "MobilePalletizingServiceUnitTest"     mvn_t MobilePalletizingServiceUnitTest
skip T "targeted mvn test rows (AC-7a is the real Fix A gate)" "enable after tests are authored"

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
