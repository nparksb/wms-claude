#!/usr/bin/env bash
# verify-260709-multi-unitload-replen-reserve-availability-guard.sh
#
# Acceptance for plan:
#   sbdocs/1-Projects/wms1/plan/260709-multi-unitload-replen-reserve-availability-guard.md
#
# Fix: MobileReplenishService.validateUnitLoadEntry must validate AVAILABILITY
# (amount - reservedamount), not gross amount, with a self-source add-back for the
# template order's own current source, and reject an already-reserved UL up front
# with MsgUnitLoadStockAlreadyReserved — instead of exploding downstream in
# changeReservedAmount with CANNOT_RESERVE_MORE_THAN_AVAILABLE (0.0000).
#
# Run after every implementation pass:
#   $ bash sbdocs/9-System/scripts/verify-260709-multi-unitload-replen-reserve-availability-guard.sh
#
# Exit code 0 iff all checks pass. Override PROJECT_ROOT for a non-default checkout.

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

skip() {
    printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1))
}

file_contains() { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2" 2>/dev/null; }
# Multi-line variant — perl -0777 so the regex can span newlines.
file_contains_ml() {
    [ -f "$2" ] || return 1
    PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null
}

# A maven test class exists and currently passes (trust mvn's exit code).
mvn_test_passes() {
    local cls=$1
    mvn test -Dtest="$cls" -DfailIfNoTests=false >/dev/null 2>&1
}

SVC=src/main/java/net/aim_ai/wms/service
MRS=$SVC/mobile/MobileReplenishService.java
MSG=src/main/resources/messages_en_US.properties
MRT=src/test/java/net/aim_ai/wms/unit/service/mobile/MobileReplenishServiceUnitTest.java

echo
echo "verify-260709-multi-unitload-replen-reserve-availability-guard — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# --- G1 — availability gate replaces gross gate (positive) --------------------
run G1a "G1 — validateUnitLoadEntry uses getAvailableamount() (availability, not gross)" \
    file_contains 'getAvailableamount\(\)' "$MRS"

# --- G1neg — old gross check is GONE (negative) -------------------------------
run G1neg "G1 — old gross gate 'getAmount().compareTo(dto.getQty())' removed" \
    file_not_contains 'getAmount\(\)\.compareTo\(\s*dto\.getQty\(\)\s*\)' "$MRS"

# --- G2 — self-source add-back present (positive) -----------------------------
run G2a "G2 — self-source guard compares template.getStockunitId() to matching stock id" \
    file_contains_ml 'template\.getStockunitId\(\)[^;]*\.equals\([^;]*getId\(\)\)' "$MRS"
# Specific to the add-back (plain getRequestedamount() usage already exists elsewhere
# in this file @297/564/599, so match the `.add( ... getRequestedamount())` shape).
run G2b "G2 — self-source add-back adds template.getRequestedamount() into effective-available" \
    file_contains_ml '\.add\([^;)]*getRequestedamount\(\)\s*\)' "$MRS"

# --- G3 — new rejection message key thrown + defined --------------------------
run G3a "G3 — validateUnitLoadEntry throws MsgUnitLoadStockAlreadyReserved" \
    file_contains 'MsgUnitLoadStockAlreadyReserved' "$MRS"
run G3b "G3 — MsgUnitLoadStockAlreadyReserved defined in messages_en_US.properties" \
    file_contains '^MsgUnitLoadStockAlreadyReserved=' "$MSG"

# --- G4 — AC-6 later-position self-source regression pin present (M-1) --------
# The single most important test (a later-position self-source in a two-UL request);
# its absence silently reintroduces the bug if applyExplicitSourceToOrder's release narrows.
run G4a "G4 — AC-6 later-position self-source test present (M-1 regression pin)" \
    file_contains 'selfSourceSecondUnitLoad_succeeds' "$MRT"

# --- Behavioral gate — unit tests (incl. AC-4/5/6 self-source cases) ----------
if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T-MRS "T — MobileReplenishServiceUnitTest passes (incl. AC-1..AC-6)" \
        mvn_test_passes MobileReplenishServiceUnitTest
else
    skip T-mvn "Targeted unit-test run" "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
