#!/usr/bin/env bash
# verify-SBDEV-2216-finishtransfer-bulk-bol-close-perf.sh
#
# Acceptance for SBDEV-2216 — finishTransfer bulk BOL close performance (v2).
#
# v2 already has the bulk fix (commits 02e1ae8e, acdafb06, 5cea7a5d, 4a0e8761,
# 595e7646, 58ad0f36). This script asserts:
#
#   - POSITIVE: the bulk pattern is still in place at the right call-sites.
#   - NEGATIVE: the v1 antipatterns (per-stockunit / per-pallet loops, class-
#               level @Transactional) are NOT present *inside* the finishTransfer
#               body. NEGATIVE checks use a method-window extraction so that
#               legitimate uses elsewhere in the file (e.g. closeBOL) do not
#               false-positive.
#   - HARDENING: the G5 elapsed-time INFO log is present, the G8 verify-count
#                unit test exists, and the G1 integration test class exists.
#
# Run after every implementation pass:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2216-finishtransfer-bulk-bol-close-perf.sh
#
# Skip the maven invocation (B1) with:
#   $ SKIP_MVN=1 bash sbdocs/9-System/scripts/verify-SBDEV-2216-finishtransfer-bulk-bol-close-perf.sh

set -u

# PATH hardening — sandboxed shells / bare CI runners may launch without
# /usr/bin on PATH, in which case grep/awk/perl all silently 127-fail and
# every `run` block reports a confusing FAIL. Front-load the standard PATH
# AND fail loudly if a required tool is missing.
export PATH="/usr/bin:/bin:${PATH}"
for cmd in grep awk perl; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "FATAL: required tool '$cmd' not found on PATH ($PATH)"
        exit 2
    }
done

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
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

# --- assertion helpers --------------------------------------------------------

file_contains()      { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains()  { ! grep -qE "$1" "$2" 2>/dev/null; }

# Multi-line variant — uses perl -0777 so the regex can span newlines.
# `s` flag (dotall) lets `.` match newlines for cross-line patterns.
# `m` flag is preserved so `^`/`$` anchor at line boundaries when authors use them.
file_contains_ml() {
    PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/ms; exit 1' "$2" 2>/dev/null
}

# Extract the body of the *private* finishTransfer(Billoflading ...) method
# from BillofladingService.java. We scope the negative checks to this body so
# closeBOL's legitimate uses of findByCarrierunitloadId / findByUnitloadId
# (lines 762, 764 in v2) do not produce false-positive FAILs.
#
# Strategy: use awk to extract from `private void finishTransfer(Billoflading`
# up to the next top-level `public ` declaration in the file. Brace-counting
# is brittle for Java; the next-public-method anchor is robust because the
# method is followed by `public List<FacilityDto> getFacilities()` at line 1028.
#
# KNOWN FAILURE MODES of this awk window (revisit if a future commit triggers
# any of these):
#   1. A new `public` overload of finishTransfer (e.g. `public void
#      finishTransfer(Billoflading)`) introduced *after* the private would be
#      consumed as the terminator before the body fully extracts — the window
#      could end mid-method. Today only one private overload exists.
#   2. Reordering: if a future refactor moves the private finishTransfer below
#      `getFacilities()`, the next-public anchor would fire on a method that
#      precedes finishTransfer in the file, producing an empty window.
#   3. Indentation drift: the `^    public ` anchor assumes 4-space indent
#      (matches existing style; the file uses spaces, not tabs).
# If any of these conditions become true, replace this with a brace-counting
# extractor or pin the body to the exact line range from `git blame`.
extract_finishtransfer_body() {
    local svc=$1
    awk '
        /private void finishTransfer\(Billoflading/ { capturing=1 }
        capturing { print }
        capturing && /^    public / && !/private void finishTransfer/ { capturing=0; exit }
    ' "$svc"
}

# Predicate: a regex pattern is present in the extracted finishTransfer body.
ft_body_contains() {
    local pattern=$1 svc=$2
    extract_finishtransfer_body "$svc" | grep -qE "$pattern"
}

# Predicate: a regex pattern is ABSENT from the extracted finishTransfer body.
ft_body_not_contains() {
    local pattern=$1 svc=$2
    ! extract_finishtransfer_body "$svc" | grep -qE "$pattern"
}

# Maven helper — exit 0 only when all tests pass.
mvn_test_passes() {
    local cls=$1
    mvn test -Dtest="$cls" -DfailIfNoTests=false >/dev/null 2>&1
}

# --- target paths -------------------------------------------------------------

SVC=src/main/java/net/aim_ai/wms/service
TEST_UNIT=src/test/java/net/aim_ai/wms/unit/service
TEST_IT=src/test/java/net/aim_ai/wms/integration

BOL=$SVC/BillofladingService.java
BOL_TEST=$TEST_UNIT/BillofladingServiceUnitTest.java

echo
echo "verify-SBDEV-2216 — finishTransfer bulk BOL close acceptance"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# === POSITIVE checks — the bulk pattern is in place ==========================

run P1 "P1 — Phase 3 bulk UPDATE BillofladingPosition (state)" \
    file_contains 'UPDATE BillofladingPosition bp SET bp\.state' "$BOL"

run P2 "P2 — Phase 4b bulk UPDATE Unitload (storagelocation + lock)" \
    file_contains_ml 'UPDATE Unitload u SET u\.storagelocationId.*u\.entityLock' "$BOL"

run P2b "P2b — Phase 4b WHERE clause (id IN :palletIds OR carrierunitloadId IN :palletIds)" \
    file_contains_ml 'u\.id IN :palletIds OR u\.carrierunitloadId IN :palletIds' "$BOL"

run P3 "P3 — Phase 4c bulk UPDATE Stockunit (entityLock via correlated subquery)" \
    file_contains_ml 'UPDATE Stockunit s SET s\.entityLock' "$BOL"

run P3b "P3b — Phase 4c subquery (Stockunit → Unitload by carrierunitloadId)" \
    file_contains_ml 's\.unitloadId IN \(SELECT u\.id FROM Unitload u WHERE u\.carrierunitloadId IN :palletIds\)' "$BOL"

run P4 "P4 — flush + clear at end of finishTransfer body" \
    file_contains_ml 'entityManager\.flush\(\);\s*\n\s*entityManager\.clear\(\);' "$BOL"

run P5 "P5 — audit batched via batchRecordForTransfer" \
    file_contains 'unitloadRecordService\.batchRecordForTransfer\(' "$BOL"

run P6 "P6 — Phase 2 bulk pre-fetch (findAllById palletUnitloadIds)" \
    file_contains 'unitloadRepository\.findAllById\(palletUnitloadIds\)' "$BOL"

run P7 "P7 — finishTransfer @Transactional specifies tenantTransactionManager" \
    file_contains_ml '@Transactional\(value = "tenantTransactionManager"[^)]*\)\s+public void finishTransfer\(String transferId\)' "$BOL"

# G5 — elapsed-time INFO log (the only NEW production code change in this plan)
# Requirement: a single LOG.info(...) statement contains all of `finishTransfer`,
# `pallets={}`, and `elapsed={}ms`. If the implementer splits the elapsed across
# two LOG.info calls, this check correctly fails — they MUST be one statement.
run P8 "P8 — G5 finishTransfer LOG.info with elapsed= and pallets=" \
    file_contains_ml 'LOG\.info\([^;]*finishTransfer[^;]*pallets=\{\}[^;]*elapsed=\{\}ms' "$BOL"

echo

# G8 — verify-count unit test method
run P9 "P9 — G8 unit test method finishTransfer_largeBOL_callsRepositoriesInBulkOnly" \
    file_contains 'finishTransfer_largeBOL_callsRepositoriesInBulkOnly' "$BOL_TEST"

# G1 — integration test class exists (Testcontainers, Hibernate Statistics)
run P10 "P10 — G1 integration test class BillofladingServiceFinishTransferIT exists" \
    test -f "$TEST_IT/service/BillofladingServiceFinishTransferIT.java"

# G2 — performance / load test class exists (@Disabled in CI)
run P11 "P11 — G2 performance test class BillofladingServiceFinishTransferPerformanceIT exists" \
    test -f "$TEST_IT/performance/BillofladingServiceFinishTransferPerformanceIT.java"

echo

# === NEGATIVE checks — v1 antipatterns are absent ============================

# Multi-line negative helper — true if the multi-line pattern is ABSENT.
file_not_contains_ml() {
    ! PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/ms; exit 1' "$2" 2>/dev/null
}

# N1 — no class-level @Transactional on BillofladingService.
# We forbid any @Transactional annotation that is *immediately followed* by
# `public class BillofladingService` (allowing whitespace / @Service in between).
run N1 "N1 — no class-level @Transactional on BillofladingService" \
    file_not_contains_ml '@Transactional[^\n]*\n(?:@\w+\s*\n)*public class BillofladingService\b' "$BOL"

# N2 — finishTransfer body does NOT contain stockunitRepository.findByUnitloadId(
run N2 "N2 — no stockunitRepository.findByUnitloadId( inside finishTransfer body (v1 antipattern)" \
    ft_body_not_contains 'stockunitRepository\.findByUnitloadId\(' "$BOL"

# N3 — finishTransfer body does NOT contain unitloadRepository.findByCarrierunitloadId(
run N3 "N3 — no unitloadRepository.findByCarrierunitloadId( inside finishTransfer body (v1 antipattern)" \
    ft_body_not_contains 'unitloadRepository\.findByCarrierunitloadId\(' "$BOL"

# N4 — finishTransfer body does NOT call unitloadBusinessService.transferUnitLoadToLocation(
run N4 "N4 — no unitloadBusinessService.transferUnitLoadToLocation( inside finishTransfer body (v1 antipattern)" \
    ft_body_not_contains 'unitloadBusinessService\.transferUnitLoadToLocation\(' "$BOL"

# N5 — Unitload / Stockunit must NOT be cached. The bulk JPQL UPDATEs in
# finishTransfer bypass the 2nd-level cache; if a future commit adds
# @Cacheable to a Unitload-/Stockunit-returning method, callers may see stale
# entries after the bulk close. Forbid @Cacheable on the affected repos and
# services. CacheConfig declares only `sysprops, clients, locations, itemdata`
# (lines 33-38 + parallel Redis bean lines 47-67) — adding new caches without
# updating this guard is the regression we want to catch.
UNITLOAD_REPO=$SVC/../repo/jpa/UnitloadRepository.java
STOCKUNIT_REPO=$SVC/../repo/jpa/StockunitRepository.java
UNITLOAD_SVC=$SVC/UnitloadService.java
STOCKUNIT_SVC=$SVC/StockunitService.java

run N5a "N5a — no @Cacheable on UnitloadRepository" \
    file_not_contains '@Cacheable' "$UNITLOAD_REPO"
run N5b "N5b — no @Cacheable on StockunitRepository" \
    file_not_contains '@Cacheable' "$STOCKUNIT_REPO"
run N5c "N5c — no @Cacheable on UnitloadService" \
    file_not_contains '@Cacheable' "$UNITLOAD_SVC"
run N5d "N5d — no @Cacheable on StockunitService" \
    file_not_contains '@Cacheable' "$STOCKUNIT_SVC"

echo

# === OPTIONAL behavior check =================================================

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run B1 "B1 — BillofladingServiceUnitTest passes (includes G8)" \
        mvn_test_passes BillofladingServiceUnitTest
else
    skip B1 "BillofladingServiceUnitTest" "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
