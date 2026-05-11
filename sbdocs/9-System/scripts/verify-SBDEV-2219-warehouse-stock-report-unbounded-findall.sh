#!/usr/bin/env bash
# verify-SBDEV-2219-warehouse-stock-report-unbounded-findall.sh
#
# Acceptance for SBDEV-2219 — WarehouseStockReportService unbounded findAll OOM remediation (v2).
# Plan:  sbdocs/1-Projects/wms2/plan/SBDEV-2219-warehouse-stock-report-unbounded-findall.md
#
# Run after every implementation pass:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2219-warehouse-stock-report-unbounded-findall.sh
#
# Exit code is 0 if all checks pass, non-zero otherwise. The implementing
# agent's end-of-task report MUST paste this script's output before the work
# is accepted.
#
# Pre-implementation baseline expectation: 1 PRE check PASS, ~24 fails for
# Fix A.1/A.2/A/B/C/D/E and audit guard (Fix F).

# Ensure mvn is on PATH (sdkman manages the Maven installation on this machine).
# Source before set -u because sdkman-init.sh references ZSH_VERSION which is
# unbound in bash — set -u would cause an immediate exit.
# shellcheck source=/dev/null
[ -f /home/nampark/.sdkman/bin/sdkman-init.sh ] && source /home/nampark/.sdkman/bin/sdkman-init.sh

set -u

# Resolve PROJECT_ROOT relative to this script's own location so the script
# works regardless of which directory it is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../../../v2/wms2-api" 2>/dev/null && pwd)}"
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

file_contains()      { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains()  { ! grep -qE "$1" "$2" 2>/dev/null; }

# Multi-line variant — uses perl -0777 so the regex can span newlines.
file_contains_ml() {
    PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null
}

mvn_test_passes() {
    # Verify at least 1 test ran — -DfailIfNoTests=false lets an empty selector
    # silently pass. Check for "Tests run: [1-9]" in the log.
    local cls=$1
    local tmplog
    tmplog=$(mktemp /tmp/mvn-test-XXXXXX.log)
    if mvn test -Dtest="$cls" -DfailIfNoTests=false >"$tmplog" 2>&1 \
            && grep -qE "Tests run: [1-9]" "$tmplog"; then
        rm -f "$tmplog"
        return 0
    else
        echo "  [mvn output tail for $cls:]" >&2
        tail -20 "$tmplog" >&2
        rm -f "$tmplog"
        return 1
    fi
}

mvn_it_passes() {
    local cls=$1
    local tmplog
    tmplog=$(mktemp /tmp/mvn-it-XXXXXX.log)
    if mvn jacoco:prepare-agent failsafe:integration-test -Dit.test="$cls" -DfailIfNoTests=false >"$tmplog" 2>&1; then
        rm -f "$tmplog"
        return 0
    else
        echo "  [mvn IT output tail for $cls:]" >&2
        tail -20 "$tmplog" >&2
        rm -f "$tmplog"
        return 1
    fi
}

SVC=src/main/java/net/aim_ai/wms/service
REPO=src/main/java/net/aim_ai/wms/repo/jpa
JOB=src/main/java/net/aim_ai/wms/schedulejob
CTRL=src/main/java/net/aim_ai/wms/controller
RES=src/main/resources
TST_SVC=src/test/java/net/aim_ai/wms/unit/service
TST_JOB=src/test/java/net/aim_ai/wms/unit/schedulejob

WSRS=$SVC/WarehouseStockReportService.java
SVR=$REPO/StockViewRepository.java
SSEJ=$JOB/StockSummaryExportJob.java
WMSC=$SVC/WmsConstants.java
MSG=$RES/messages_en_US.properties
WSRS_TEST=$TST_SVC/WarehouseStockReportServiceUnitTest.java
SSEJ_TEST=$TST_JOB/StockSummaryExportJobUnitTest.java
IRS=$SVC/InventoryRecordService.java

echo
echo "verify-SBDEV-2219 — WarehouseStockReportService unbounded findAll acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# === PRE — already-done baseline (1 PASS expected before any new work) =======

# PRE-1: StockViewRepository extends ReadOnlyPagingAndSortingRepository<StockView, Long>
# (already in place — Fix A only adds a new streaming method on top).
run PRE-1 "Prereq — StockViewRepository extends ReadOnlyPagingAndSortingRepository<StockView, Long>" \
    file_contains 'extends\s+ReadOnlyPagingAndSortingRepository<StockView,\s*Long>' "$SVR"

echo

# === Fix A.1 — InventoryRecordService.createEntity REQUIRES_NEW (BLOCKER) ====

# P1: InventoryRecordService.createEntity is annotated with Propagation.REQUIRES_NEW.
# Without this, the method joins the outer readOnly=true tx and Postgres rejects
# every INSERT with "cannot execute INSERT in a read-only transaction".
# H2 does NOT catch this (H2 ignores setReadOnly at SQL level) — this grep is
# the only automated gate; staging Postgres smoke is the execution proof.
run P1 "Fix A.1 — InventoryRecordService.createEntity annotated Propagation.REQUIRES_NEW" \
    bash -c '
        perl -0777 -ne "exit 0 if /createEntity[\s\S]{0,400}REQUIRES_NEW/m; exit 1" "'"$IRS"'" 2>/dev/null \
        || perl -0777 -ne "exit 0 if /REQUIRES_NEW[\s\S]{0,400}createEntity/m; exit 1" "'"$IRS"'" 2>/dev/null
    '

echo

# === Fix A.2 — getStockCount() shim + legacyGetStockCount() bridge ===========

# P2 (NEGATIVE): public getStockCount() is @Deprecated AND its body throws UnsupportedOperationException.
# Both signals must be present together — @Deprecated alone is not sufficient.
run P2 "Fix A.2 — public getStockCount() is @Deprecated and throws UnsupportedOperationException" \
    bash -c '
        perl -0777 -ne "exit 0 if /\@Deprecated[\s\S]{0,300}?getStockCount\s*\(\s*\)[\s\S]{0,300}?UnsupportedOperationException/m; exit 1" "'"$WSRS"'" 2>/dev/null \
        || perl -0777 -ne "exit 0 if /UnsupportedOperationException[\s\S]{0,300}?getStockCount\s*\(\s*\)[\s\S]{0,300}?\@Deprecated/m; exit 1" "'"$WSRS"'" 2>/dev/null
    '

# P3 (POSITIVE): private legacyGetStockCount() exists — the rollback-toggle bridge.
run P3 "Fix A.2 — private legacyGetStockCount() method exists in WarehouseStockReportService" \
    file_contains 'private\s+\S.*legacyGetStockCount\s*\(\s*\)' "$WSRS"

echo

# === Fix A — streaming repository method + @Transactional ====================

# A1: StockViewRepository declares a Stream<StockView> return type.
run A1 "Fix A — StockViewRepository declares Stream<StockView> return type" \
    file_contains 'Stream<StockView>' "$SVR"

# A2: StockViewRepository declares the @QueryHints fetch-size hint.
# Match either the constant HINT_FETCH_SIZE OR the literal "org.hibernate.fetchSize".
run A2 "Fix A — StockViewRepository declares @QueryHint with HINT_FETCH_SIZE (or literal name)" \
    bash -c '
        grep -qE "@QueryHint(s)?\s*\(" "'"$SVR"'" 2>/dev/null \
        && (grep -qE "HINT_FETCH_SIZE" "'"$SVR"'" 2>/dev/null \
            || grep -qE "org\.hibernate\.fetchSize" "'"$SVR"'" 2>/dev/null)
    '

# A3: WarehouseStockReportService declares @Transactional(value = "tenantTransactionManager", readOnly = true)
# on the new streaming method (regardless of whether it's named streamStockCount).
run A3 "Fix A — WarehouseStockReportService declares @Transactional(tenantTransactionManager, readOnly=true)" \
    bash -c '
        perl -0777 -ne "exit 0 if /\@Transactional\([^)]*tenantTransactionManager[^)]*readOnly\s*=\s*true/m; exit 1" "'"$WSRS"'" 2>/dev/null \
        || perl -0777 -ne "exit 0 if /\@Transactional\([^)]*readOnly\s*=\s*true[^)]*tenantTransactionManager/m; exit 1" "'"$WSRS"'" 2>/dev/null
    '

# A4: WarehouseStockReportService exposes a streaming consumer or stream-returning method.
# Accept any of: streamStockCount, streamAllBy, Stream<StockCountDto>, Consumer<StockCountDto>.
run A4 "Fix A — WarehouseStockReportService exposes streaming API (streamStockCount / Consumer<StockCountDto>)" \
    bash -c '
        grep -qE "streamStockCount|Stream<StockCountDto>|Consumer<StockCountDto>" "'"$WSRS"'" 2>/dev/null
    '

# A5 (NEGATIVE): the unbounded (List<StockView>) cast over findAll() at line 28 is gone.
run A5 "Fix A — WarehouseStockReportService no longer contains '(List<StockView>) stockViewRepository.findAll()'" \
    file_not_contains '\(List<StockView>\)\s*stockViewRepository\.findAll\(\s*\)' "$WSRS"

echo

# === Fix B — StockSummaryExportJob refactor to consume the stream ============

# B1 (POSITIVE): StockSummaryExportJob references the new streaming method.
run B1 "Fix B — StockSummaryExportJob references streamStockCount (or Consumer<StockCountDto>)" \
    bash -c '
        grep -qE "streamStockCount|Consumer<StockCountDto>" "'"$SSEJ"'" 2>/dev/null
    '

# B2 (NEGATIVE): the no-arg getStockCount() invocation is gone from StockSummaryExportJob.
# Match the original "warehouseStockReportService.getStockCount();" (no args) call form.
run B2 "Fix B — StockSummaryExportJob no longer calls warehouseStockReportService.getStockCount() (no-arg)" \
    file_not_contains 'warehouseStockReportService\.getStockCount\(\s*\)\s*;' "$SSEJ"

# B3: per-row inventoryRecordService.createEntity invocation is preserved (must be called inside the stream lambda).
run B3 "Fix B — StockSummaryExportJob still calls inventoryRecordService.createEntity per row" \
    file_contains 'inventoryRecordService\.createEntity' "$SSEJ"

echo

# === Fix C — configurable hard cap ===========================================

# C1: WmsConstants declares the new sysprop key.
run C1 "Fix C — WmsConstants declares SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_MAX_ROWS_KEY" \
    file_contains 'SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_MAX_ROWS_KEY' "$WMSC"

# C2: WarehouseStockReportService references the cap key (used in the count-and-throw guard).
run C2 "Fix C — WarehouseStockReportService references SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_MAX_ROWS_KEY" \
    file_contains 'SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_MAX_ROWS_KEY' "$WSRS"

# C3: WarehouseStockReportService throws BusinessException with the StockCountTooLarge i18n key.
run C3 "Fix C — WarehouseStockReportService references BusinessException.StockCountTooLarge" \
    file_contains 'BusinessException\.StockCountTooLarge|StockCountTooLarge' "$WSRS"

# C4: messages_en_US.properties contains the new i18n key.
run C4 "Fix C — messages_en_US.properties contains BusinessException.StockCountTooLarge" \
    file_contains '^BusinessException\.StockCountTooLarge=' "$MSG"

# C5: WarehouseStockReportService calls stockViewRepository.count() before opening the stream
#     (the count-and-throw guard must invoke count()).
run C5 "Fix C — WarehouseStockReportService calls stockViewRepository.count() (cap guard)" \
    file_contains 'stockViewRepository\.count\(\s*\)' "$WSRS"

# C6: WmsConstants declares the no-split ceiling constant (M1 — prevents no-split path from
#     buffering Integer.MAX_VALUE rows and restoring O(rows) heap).
run C6 "Fix C/B — WmsConstants declares STOCK_SUMMARY_EXPORT_NO_SPLIT_MAX_CHUNK constant" \
    file_contains 'STOCK_SUMMARY_EXPORT_NO_SPLIT_MAX_CHUNK' "$WMSC"

echo

# === Fix D — HAL endpoint hygiene ===========================================

# D1: StockViewRepository suppresses ALL three inherited findAll overloads:
#   - findAll()          (CrudRepository — no args)
#   - findAll(Pageable)  (PagingAndSortingRepository)
#   - findAll(Sort)      (PagingAndSortingRepository — M3: this was missing in the first draft)
# Strategy: count occurrences of @RestResource(exported = false) near findAll.
# Require at least 3 such suppressions (one per overload) OR a single class-level suppression.
run D1 "Fix D — StockViewRepository suppresses findAll(), findAll(Pageable), AND findAll(Sort) via @RestResource(exported=false)" \
    bash -c '
        # Count @RestResource(exported = false) annotations that appear within 5 lines of a findAll method.
        # Accept >= 3 hits (one per overload) OR a class-level @RepositoryRestResource(exported=false).
        count=$(perl -0777 -ne "
            my \$text = \$_;
            my \$hits = 0;
            while (\$text =~ /\@RestResource\s*\(\s*exported\s*=\s*false\s*\)[\s\S]{0,300}?findAll/mg) { \$hits++ }
            while (\$text =~ /findAll[\s\S]{0,150}?\@RestResource\s*\(\s*exported\s*=\s*false\s*\)/mg) { \$hits++ }
            print \$hits
        " "'"$SVR"'" 2>/dev/null)
        [ "${count:-0}" -ge 3 ]
    '

echo

# === Fix E — Logger class reference cleanup =================================

# E1 (POSITIVE): WarehouseStockReportService references LoggerFactory.getLogger(WarehouseStockReportService.class).
run E1 "Fix E — WarehouseStockReportService uses LoggerFactory.getLogger(WarehouseStockReportService.class)" \
    file_contains 'LoggerFactory\.getLogger\(\s*WarehouseStockReportService\.class\s*\)' "$WSRS"

# E2 (NEGATIVE): the wrong-class reference is gone.
run E2 "Fix E — WarehouseStockReportService no longer references LoggerFactory.getLogger(ReceivingService.class)" \
    file_not_contains 'LoggerFactory\.getLogger\(\s*ReceivingService\.class\s*\)' "$WSRS"

echo

# === Fix F — Repository.findAll() audit guard (count-only) ==================

# F1: Count Repository.findAll() callsites in service/ + controller/ packages.
# Pre-fix: 4 (WarehouseStockReport, Access, UtilRest, OrderRest).
# Post-fix: <= 4 — the count stays at 4 because Fix A's NEW-2 rollback-toggle design
# (critic-approved) preserves the unbounded findAll() inside a private legacyGetStockCount()
# bridge, gated behind STOCK_SUMMARY_EXPORT_STREAMING_ENABLED. The 4 grandfathered sites:
#   1. WarehouseStockReportService.legacyGetStockCount() — rollback bridge (was getStockCount())
#   2. AccessService — UserFunction permission catalog (low volume)
#   3. UtilRestController — LocationConstraint
#   4. OrderRestController — Shipperid
# A NEW Repository.findAll() addition (a 5th site) would FAIL this check.
# Regex uses \s* to handle any whitespace (including multiple spaces) between
# the repository variable and .findAll() — avoids m2 brittleness from reformatting.
# Excludes lines that are pure comments (starts with optional whitespace + // or *).
run F1 "Fix F — Repository.findAll() count in service/+controller/ is <= 4 (rollback-bridge + 3 grandfathered)" \
    bash -c '
        count=$(grep -rE "\bfindAll\s*\(\s*\)" \
                  src/main/java/net/aim_ai/wms/service/ \
                  src/main/java/net/aim_ai/wms/controller/ \
                2>/dev/null \
                | grep -vE "^\s*(//|\*)" \
                | wc -l)
        [ "$count" -le 4 ]
    '

echo

# === Test wiring ==============================================================

# T1: WarehouseStockReportServiceUnitTest references the new streaming method.
run T1 "Test — WarehouseStockReportServiceUnitTest references streamStockCount" \
    bash -c '
        test -f "'"$WSRS_TEST"'" && grep -qE "streamStockCount" "'"$WSRS_TEST"'" 2>/dev/null
    '

# T2: StockSummaryExportJobUnitTest references inventoryRecordService.createEntity (per-row contract).
run T2 "Test — StockSummaryExportJobUnitTest references inventoryRecordService.createEntity" \
    bash -c '
        test -f "'"$SSEJ_TEST"'" && grep -qE "inventoryRecordService\)?\.createEntity|createEntity\(" "'"$SSEJ_TEST"'" 2>/dev/null
    '

# T3: StockSummaryExportJobUnitTest references streamStockCount in stub/verify (proves the test
# was updated for the new contract, not just inherited from old fixture).
run T3 "Test — StockSummaryExportJobUnitTest references streamStockCount" \
    bash -c '
        test -f "'"$SSEJ_TEST"'" && grep -qE "streamStockCount" "'"$SSEJ_TEST"'" 2>/dev/null
    '

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T-WSRS "Test — mvn test -Dtest=WarehouseStockReportServiceUnitTest passes" \
        mvn_test_passes WarehouseStockReportServiceUnitTest
    run T-SSEJ "Test — mvn test -Dtest=StockSummaryExportJobUnitTest passes" \
        mvn_test_passes StockSummaryExportJobUnitTest
    # T-IT: Plan §6 prescribed integration test — heap-bound + consumer-count contract for
    # streamStockCount against a seeded H2-in-PG-mode dataset. H2 cursor-streaming caveat
    # documented in the IT's class Javadoc per plan §6.
    run T-IT "Test — mvn failsafe:integration-test -Dit.test=WarehouseStockReportServiceStreamIT passes" \
        mvn_it_passes WarehouseStockReportServiceStreamIT
else
    skip T-WSRS "Test — WarehouseStockReportServiceUnitTest run" "SKIP_MVN=1 set"
    skip T-SSEJ "Test — StockSummaryExportJobUnitTest run" "SKIP_MVN=1 set"
    skip T-IT "Test — WarehouseStockReportServiceStreamIT run" "SKIP_MVN=1 set"
fi

echo

# === Codebase-wide hardening sanity ==========================================

# H1: Zero (List<StockView>) cast over findAll() anywhere in src/main/java.
# Matches both the original site AND any copy-paste regression.
run H1 "Hardening — zero '(List<StockView>) <repo>.findAll()' casts in src/main/java" \
    bash -c '
        count=$(grep -rE "\(List<StockView>\)\s*\w+\.findAll\(\s*\)" src/main/java 2>/dev/null | wc -l)
        [ "$count" -eq 0 ]
    '

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
