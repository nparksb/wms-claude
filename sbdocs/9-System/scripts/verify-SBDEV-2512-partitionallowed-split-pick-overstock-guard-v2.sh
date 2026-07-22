#!/usr/bin/env bash
# verify-SBDEV-2512-partitionallowed-split-pick-overstock-guard-v2.sh
#
# Acceptance for plan:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2512-partitionallowed-split-pick-overstock-guard.md
#
# v2 PORT of v1 SBDEV-2512 (PR #194 / b9655bf). Honor partitionallowed=false in
# overstock release on v2/wms2-api: a non-partitionable CustomerorderPosition that
# cannot be filled from a SINGLE covering stock unit is HELD (Fix A, ROUND 2) instead
# of fragmented; a fillable one gets exactly ONE pick (Fix B, PHASE 3). Both gate on
# the default-ON ENFORCE_PARTITIONALLOWED kill-switch (SyspropService.getSysvalue).
# NEW-1: releaseOrder's @Transactional must carry all three attributes incl. rollbackFor.
# S6: the two StockunitRepository candidate queries must stay equivalent except FOR UPDATE.
#
# Baseline expectation: ALL checks FAIL before implementation (guard code absent).
#
# Run:  bash sbdocs/9-System/scripts/verify-SBDEV-2512-partitionallowed-split-pick-overstock-guard-v2.sh
# Exit 0 iff all checks pass. Override PROJECT_ROOT for a non-default checkout.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0
run()  { local id=$1 desc=$2; shift 2; if "$@" >/dev/null 2>&1; then printf "  PASS  %-8s  %s\n" "$id" "$desc"; PASS=$((PASS+1)); else printf "  FAIL  %-8s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi; }
skip() { printf "  SKIP  %-8s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }
file_contains()   { grep -qE "$1" "$2" 2>/dev/null; }
count_at_least()  { [ "$(grep -cE "$1" "$2" 2>/dev/null)" -ge "$3" ]; }
# set +u around the sdkman source: sdkman-init.sh references unbound vars that would trip the script's set -u.
mvn_test_passes() { set +u; source "$HOME/.sdkman/bin/sdkman-init.sh" >/dev/null 2>&1; local rc; mvn -o test -Dtest="$1" -DfailIfNoTests=false -Dmaven.javadoc.skip=true >/dev/null 2>&1; rc=$?; set -u; return $rc; }

CONST=src/main/java/net/aim_ai/wms/service/WmsConstants.java
ROJS=src/main/java/net/aim_ai/wms/service/job/ReleaseOrderJobService.java
SUREPO=src/main/java/net/aim_ai/wms/repo/jpa/StockunitRepository.java
TEST=src/test/java/net/aim_ai/wms/unit/service/job/ReleaseOrderJobServiceUnitTest.java

echo
echo "verify-SBDEV-2512-partitionallowed-split-pick-overstock-guard-v2 — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# --- kill-switch constant + read ---------------------------------------------
run V1 "WmsConstants defines SYSTEM_PROPERTY_ENFORCE_PARTITIONALLOWED_KEY" \
    file_contains 'SYSTEM_PROPERTY_ENFORCE_PARTITIONALLOWED_KEY\s*=\s*"ENFORCE_PARTITIONALLOWED"' "$CONST"
run V2 "releaseOrder reads the kill-switch via getSysvalue(...ENFORCE_PARTITIONALLOWED...)" \
    file_contains 'getSysvalue\(\s*WmsConstants\.SYSTEM_PROPERTY_ENFORCE_PARTITIONALLOWED_KEY' "$ROJS"

# --- Fix A: cumulative ROUND 2 hold ------------------------------------------
run V3a "reserveSingleCoveringUnit helper present" \
    file_contains 'private boolean reserveSingleCoveringUnit\(' "$ROJS"
run V3b "reserveSingleCoveringUnit seeds ledger from NON-locking getStockUnitsByItemDataId" \
    file_contains 'getStockUnitsByItemDataId\(' "$ROJS"
run V3c "Fix A holds via named RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION (not literal 55)" \
    file_contains 'RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION' "$ROJS"

# --- getPartitionallowed read in BOTH loci (Fix A round-2 + Fix B phase-3) ----
run V4 "getPartitionallowed() read >=2x (Fix A guard + Fix B phase-3 branch)" \
    count_at_least 'getPartitionallowed\(\)' "$ROJS" 2

# --- Fix B: phase-3 single-covering-unit failsafe ----------------------------
run V5 "Fix B failsafe throws BusinessException 'SBDEV-2512: no single stock unit covers'" \
    file_contains 'SBDEV-2512: no single stock unit covers non-partitionable position' "$ROJS"

# --- NEW-1 / AC-8: three-attribute @Transactional on releaseOrder (MULTILINE) -
# The annotation may wrap across lines under a formatter; span from @Transactional
# to the releaseOrder signature with a null-data PCRE match, then assert each attr.
ac8_annotation_full() {
    local span
    span="$(grep -Pzo '@Transactional[\s\S]*?public\s+Map<Long,\s*Integer>\s+releaseOrder' "$ROJS" 2>/dev/null | tr '\0' '\n')"
    [ -n "$span" ] || return 1
    printf '%s' "$span" | grep -q 'value\s*=\s*"tenantTransactionManager"' || return 1
    printf '%s' "$span" | grep -q 'propagation\s*=\s*Propagation\.REQUIRES_NEW' || return 1
    printf '%s' "$span" | grep -q 'rollbackFor' || return 1
    printf '%s' "$span" | grep -q 'BusinessException\.class' || return 1
    printf '%s' "$span" | grep -q 'FacadeException\.class' || return 1
    return 0
}
run V6 "AC-8: releaseOrder @Transactional carries value=tenantTransactionManager + REQUIRES_NEW + rollbackFor{BusinessException,FacadeException}" \
    ac8_annotation_full

# --- S6 / V-check: dual-query equivalence guard on StockunitRepository --------
run V7a "both stock-unit candidate queries filter amount > reservedAmount" \
    count_at_least 'amount > stockUnit\.reservedAmount|amount > stockunit\.reservedAmount|amount\s*>\s*stockUnit\.reservedAmount' "$SUREPO" 2
run V7b "both stock-unit candidate queries ORDER BY stockUnit.amount DESC" \
    count_at_least 'ORDER BY stockUnit\.amount DESC' "$SUREPO" 2
# S6 comment spans multiple lines on BOTH methods; assert the marker appears on both (>=2) plus the
# equivalence intent keyword ("byte-identical") — line-based grep, no multiline needed.
s6_comment_present() {
    count_at_least '\[SBDEV-2512\]' "$SUREPO" 2 && file_contains 'byte-identical' "$SUREPO"
}
run V7c "S6 equivalence comment present on BOTH StockunitRepository methods (SBDEV-2512)" \
    s6_comment_present

# --- behavioral gate — unit tests (incl. AC-5 divergence, AC-6 cumulative hold)
if command -v mvn >/dev/null 2>&1 || [ -f "$HOME/.sdkman/candidates/maven/current/bin/mvn" ]; then
    run V8 "mvn test ReleaseOrderJobServiceUnitTest passes (incl. AC-1/AC-5/AC-6)" \
        mvn_test_passes ReleaseOrderJobServiceUnitTest
else
    skip V8 "mvn behavioral gate" "mvn not on PATH (source sdkman-init.sh)"
fi

# --- AC presence sanity (red→green + pinning) in the test class --------------
run V9 "ReleaseOrderJobServiceUnitTest contains SBDEV-2512 acceptance tests" \
    file_contains 'SBDEV-2512|partitionallowed|reserveSingleCoveringUnit' "$TEST"

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ] || exit 1
