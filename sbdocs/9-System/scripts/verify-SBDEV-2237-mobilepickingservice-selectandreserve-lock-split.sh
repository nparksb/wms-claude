#!/usr/bin/env bash
# verify-SBDEV-2237-mobilepickingservice-selectandreserve-lock-split.sh
# Machine-checkable acceptance for SBDEV-2237 (MobilePickingService lock-window split).
#
# Plan: sbdocs/1-Projects/wms2/plan/SBDEV-2237-mobilepickingservice-selectandreserve-lock-split.md
#
# Usage:
#   bash sbdocs/9-System/scripts/verify-SBDEV-2237-mobilepickingservice-selectandreserve-lock-split.sh
#   SKIP_MVN=1 bash sbdocs/9-System/scripts/verify-SBDEV-2237-mobilepickingservice-selectandreserve-lock-split.sh
#
# Exits 0 if all checks PASS; non-zero otherwise.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

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

# --- assertion helpers ---
file_contains()     { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }

mvn_test_passes() {
    local test_class=$1
    mvn test -Dtest="$test_class" -DfailIfNoTests=false -q 2>&1 \
        | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0"
}

# Paths under test (relative to PROJECT_ROOT)
CTRL=src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java
REPO=src/main/java/net/aim_ai/wms/repo/jpa/PickingorderRepository.java
TST=src/test/java/net/aim_ai/wms/unit/service/mobile/MobilePickingServiceUnitTest.java

echo
echo "verify-SBDEV-2237 — MobilePickingService.selectAndReservePickingOrder lock-window split"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# === §A — PickingorderRepository lock timeout (Fix B / AC1) ====================

run A1 "AC1 — @QueryHints(jakarta.persistence.lock.timeout=1000) on findByIdForUpdate" \
    file_contains 'jakarta\.persistence\.lock\.timeout.*"1000"|"1000".*jakarta\.persistence\.lock\.timeout' "$REPO"

run A2 "AC1 — QueryHints import present" \
    file_contains 'import org\.springframework\.data\.jpa\.repository\.QueryHints;' "$REPO"

run A3 "AC1 — QueryHint import present (jakarta.persistence.QueryHint)" \
    file_contains 'import jakarta\.persistence\.QueryHint;' "$REPO"

echo

# === §B — Tx-1 claimPickingOrderAtomically (Fix A / AC2) =======================

run B1 "AC2 — claimPickingOrderAtomically method exists in MobilePickingService" \
    file_contains 'claimPickingOrderAtomically' "$CTRL"

run B2 "AC2 — @Qualifier(\"tenantTransactionManager\") PlatformTransactionManager injection present" \
    file_contains '@Qualifier\("tenantTransactionManager"\).*PlatformTransactionManager|PlatformTransactionManager.*tenantTransactionManager' "$CTRL"

run B3 "AC2 — claimPickingOrderAtomically declared private (returns ClaimResult)" \
    file_contains 'private[[:space:]]+ClaimResult[[:space:]]+claimPickingOrderAtomically' "$CTRL"

echo

# === §C — Tx-2 finalizePickingOrderForStart (Fix A / AC3) ======================

run C1 "AC3 — finalizePickingOrderForStart method exists in MobilePickingService" \
    file_contains 'finalizePickingOrderForStart' "$CTRL"

run C2 "AC3 — finalizePickingOrderForStart declared private" \
    file_contains 'private[[:space:]]+Pickingorder[[:space:]]+finalizePickingOrderForStart' "$CTRL"

echo

# === §D — Orchestrator selectAndReservePickingOrder (AC4) ======================

run D1 "AC4 — selectAndReservePickingOrder method is present" \
    file_contains 'selectAndReservePickingOrder' "$CTRL"

# TransactionTemplate sentinels — the new fields driving Tx-1 and Tx-2
run D2 "Fix-A — TransactionTemplate fields (claimTx / finalizeTx) present" \
    file_contains 'TransactionTemplate[[:space:]]+(claimTx|finalizeTx)' "$CTRL"

run D3 "Fix-A — claimTx.execute(...) invoked from orchestrator" \
    file_contains 'claimTx\.execute' "$CTRL"

run D4 "Fix-A — finalizeTx.execute(...) invoked from orchestrator" \
    file_contains 'finalizeTx\.execute' "$CTRL"

run D5 "Fix-A — releaseClaimQuietly compensating method present" \
    file_contains 'releaseClaimQuietly' "$CTRL"

run D6 "Fix-A — PROPAGATION_REQUIRES_NEW used in compensating release" \
    file_contains 'PROPAGATION_REQUIRES_NEW' "$CTRL"

run D7 "AC10 — releaseClaimQuietly accepts claimantUserId parameter" \
    file_contains 'releaseClaimQuietly\(long[^,]+,\s*Long\s+claimantUserId\)' "$CTRL"

run D8 "AC10 — releaseClaimQuietly guards with operatorId+state before resetting" \
    file_contains 'claimantUserId\.equals\(po\.getOperatorId\(\)\)' "$CTRL"

run D9 "AC10 — no-op re-claim: save skipped on freshClaim==false (conditional save in claimPickingOrderAtomically)" \
    file_contains 'freshClaim.*pickingorderRepository\.save|pickingorderRepository\.save.*freshClaim' "$CTRL"

echo

# === §E — Legacy processPickingOrderForStart deletion (AC8) ====================

run E1 "AC8 — processPickingOrderForStart method deleted from MobilePickingService" \
    file_not_contains 'processPickingOrderForStart' "$CTRL"

echo

# === §F — Test file exists & runs (AC5/AC6/AC7/AC9) ============================

run F1 "AC9 — MobilePickingServiceUnitTest source file exists" \
    test -f "$TST"

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run F2 "AC9 — MobilePickingServiceUnitTest passes (mvn test)" \
        mvn_test_passes MobilePickingServiceUnitTest
else
    skip F2 "AC9 — MobilePickingServiceUnitTest" "SKIP_MVN=1 set"
fi

echo

# ============================================================================
# §G — Lock-window guardrail: claimPickingOrderAtomically body must NOT call
#      collaborators that would re-widen the lock window
# ============================================================================

SVC=src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java

run G1 "AC-guard — claimPickingOrderAtomically body free of forbidden collaborators (would widen lock)" \
    bash -c '
        START=$(grep -n "private.*claimPickingOrderAtomically" '"$SVC"' | head -1 | cut -d: -f1)
        [ -z "$START" ] && exit 1
        END=$(awk "NR>$START && /^    \}$/ { print NR; exit }" '"$SVC"')
        [ -z "$END" ] && exit 1
        sed -n "${START},${END}p" '"$SVC"' \
          | grep -qE "pickingorderPositionRepository|pickingorderBusinessService|sectionRepository" \
          && exit 1 || exit 0
    '

run G2 "AC-guard — finalizePickingOrderForStart does NOT call findByIdForUpdate (no lock in Tx-2)" \
    bash -c '
        START=$(grep -n "private.*finalizePickingOrderForStart" '"$SVC"' | head -1 | cut -d: -f1)
        [ -z "$START" ] && exit 1
        END=$(awk "NR>$START && /^    \}$/ { print NR; exit }" '"$SVC"')
        [ -z "$END" ] && exit 1
        sed -n "${START},${END}p" '"$SVC"' \
          | grep -qE "findByIdForUpdate" \
          && exit 1 || exit 0
    '

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
