#!/usr/bin/env bash
# verify-SBDEV-2951-transfer-club-available-counts-lane-only.sh
#
# SBDEV-2951 — Transfer and Club item lists show no warehouse-wide stock figure.
# Plan: sbdocs/1-Projects/wms2/plan/SBDEV-2951-transfer-club-available-counts-lane-only.md
# Rows are specified in the plan's §9.1; ids here match that table exactly.
#
# ⚠ NEGATIVE CONTROL IS MANDATORY. Run this against unfixed origin/develop FIRST and record the
#   FAIL count in the plan's §12. Every V-*(positive) row must FAIL and every V-*(negative) row must
#   PASS on the unfixed build. A script reporting "0 fail" before any code changed asserts nothing.
#
# ⚠ Helpers below are deliberately NOT the template's. The template's file_not_contains is
#   `! grep -qE` — on a MISSING file grep exits 2, the `!` makes it true, and the row passes.
#   That fail-open behaviour has produced false greens in this vault. Every helper here guards
#   `[ -f ]` first, and the negatives strip comments so a commented-out line cannot flip them.

set -uo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude}"
API="$PROJECT_ROOT/v2/wms2-api/src/main/java/net/aim_ai/wms"
UI="$PROJECT_ROOT/v2/wms2-web-ui"

PASS=0; FAIL=0; SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-8s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-8s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

# ---- fail-closed helpers -------------------------------------------------------------------------

has() {                          # has <regex> <file>
    [ -f "$2" ] || return 1
    grep -qE "$1" "$2"
}

# Multi-line match. -0777 slurps; the [ -f ] guard is what the template omits.
has_ml() {                       # has_ml <perl-regex> <file>
    [ -f "$2" ] || return 1
    perl -0777 -ne "exit(/$1/s ? 0 : 1)" "$2"
}

# Negative: the construct must be ABSENT from real code. Comments are stripped first, so a
# commented-out occurrence cannot fail the row and a commented-out FIX cannot pass it.
lacks_code() {                   # lacks_code <regex> <file>
    [ -f "$2" ] || return 1      # missing file = FAIL, never a free pass
    ! sed -e 's://.*::' -e 's:/\*.*\*/::' "$2" | grep -qE "$1"
}

count_is() {                     # count_is <regex> <file> <n>
    [ -f "$2" ] || return 1
    [ "$(grep -cE "$1" "$2")" -eq "$3" ]
}

# ---- paths --------------------------------------------------------------------------------------

V_STOCKREPO="$API/repo/jpa/StockunitRepository.java"
V_UNITLOADREPO="$API/repo/jpa/UnitloadRepository.java"
V_CONSTANTS="$API/service/WmsConstants.java"
V_TRANSFER_SVC="$API/service/TransferOrderService.java"
V_CLUB_SVC="$API/service/CustomerorderBatchService.java"
V_DTO="$API/json/ClubLineSkuDto.java"
V_ONHAND_SVC="$API/service/OnHandQuantityService.java"
V_PROJECTION="$API/repo/projection/ItemdataOnHandView.java"

V_UI_TRANSFER="$UI/components/processes/transferPicking/itemsTable.vue"
V_UI_CLUB="$UI/components/processes/clubRuns/itemsTable.vue"
V_UI_OUTBOUND="$UI/components/outbound/transfer/transferDetailsTable.vue"

echo "SBDEV-2951 — Transfer/Club warehouse-wide on-hand figure"
echo "PROJECT_ROOT=$PROJECT_ROOT"
echo

# ---- Fix C: the query, the projection, the service ----------------------------------------------
echo "Fix C — on-hand query + shared service"

run V-C1 "sumOnHandByItemdataIds declared on StockunitRepository" \
    has 'List<ItemdataOnHandView>[[:space:]]+sumOnHandByItemdataIds' "$V_STOCKREPO"

# R2 — THE TRAP. Either the collection form or ReplenishorderRepository's two-scalar form is accepted.
#
# ⚠ The first draft of this row was `'sumOnHand[\s\S]{0,80}|NOT IN \(:...\)'`. That is an ALTERNATION,
#   so it would have passed the moment the method NAME existed — never asserting the sink exclusion at
#   all, i.e. green while R2's 2.8M-unit defect shipped. Exactly the vacuous-row failure mode this
#   vault has recorded. The form below requires the sink clause AND ties it to this method via a
#   tempered gap that cannot cross another @Query, so it cannot be satisfied by a sibling's predicate.
run V-C2 "that query excludes the sink locations (R2 — 2,856,635 units)" \
    has_ml 'NOT IN \(:(sinkLocationNames|nirvana, ?:shipped)\)(?:(?!\@Query)[\s\S]){0,900}?sumOnHandByItemdataIds' \
    "$V_STOCKREPO"

run V-C3 "that query is lock-aware and reserved-adjusted" \
    has_ml 'su\.entity_lock = 0[^;]{0,200}ul\.entity_lock = 0[^;]{0,200}lo\.entity_lock = 0[^;]{0,400}su\.amount > su\.reservedamount' \
    "$V_STOCKREPO"

# Tempered-greedy gap on ';' -- the terminator of one interface declaration -- so this asserts
# ADJACENCY, not mere co-presence in a 220-line repository interface where six siblings already
# carry exported = false. Proven red when the annotation is absent AND when it belongs to a
# different method.
#
# ⚠ The gap tempers on ';', NOT on 'List<': the target method's OWN return type is
#   List<ItemdataOnHandView>, so tempering on 'List<' made this row permanently red — a red row
#   that no correct implementation can turn green is indistinguishable from unfinished work.
run V-C4 "@RestResource(exported = false) immediately precedes it (R4)" \
    has_ml '\@RestResource\(exported = false\)(?:(?!;)[\s\S]){0,1200}?sumOnHandByItemdataIds' \
    "$V_STOCKREPO"

run V-C5 "ItemdataOnHandView projection exists with a typed getAmount" \
    has 'BigDecimal[[:space:]]+getAmount' "$V_PROJECTION"

run V-C6 "OnHandQuantityService uses the tenant TM, read-only" \
    has_ml 'tenantTransactionManager[\s\S]{0,120}readOnly = true|readOnly = true[\s\S]{0,120}tenantTransactionManager' \
    "$V_ONHAND_SVC"

run V-C7 "empty-itemdataIds guard present (empty IN () is a SQL error)" \
    has 'isEmpty\(\)' "$V_ONHAND_SVC"

# ---- Fix A/B: the two overviews -----------------------------------------------------------------
echo
echo "Fix A/B — both overviews populate it; the lane figure is untouched"

run V-A1a "transfer overview sets amountOnHand" has 'setAmountOnHand\(' "$V_TRANSFER_SVC"
run V-A1b "club overview sets amountOnHand"     has 'setAmountOnHand\(' "$V_CLUB_SVC"

# R1/R10 — the lane figure and its zero branch MUST survive. It gates Run Transfer / Run Club Line.
run V-A2a "transfer still sets amountAvailable(0) on no lane (R1)" \
    has 'setAmountAvailable\(0\)' "$V_TRANSFER_SVC"
run V-A2b "club still sets amountAvailable(0) on no lane (R1/R10)" \
    has 'setAmountAvailable\(0\)' "$V_CLUB_SVC"

run V-A3a "transfer never feeds on-hand into amountAvailable (R1)" \
    lacks_code 'setAmountAvailable\((onHand|amountOnHand)' "$V_TRANSFER_SVC"
run V-A3b "club never feeds on-hand into amountAvailable (R1)" \
    lacks_code 'setAmountAvailable\((onHand|amountOnHand)' "$V_CLUB_SVC"

# R3/AC8 — exactly one batch call per service, not one per position.
run V-A4a "transfer calls onHandByItemdata exactly once (R3/AC8)" \
    count_is 'onHandByItemdata\(' "$V_TRANSFER_SVC" 1
run V-A4b "club calls onHandByItemdata exactly once (R3/AC8)" \
    count_is 'onHandByItemdata\(' "$V_CLUB_SVC" 1

run V-B1 "ClubLineSkuDto exposes amountOnHand additively" \
    has_ml 'setAmountOnHand[\s\S]{0,400}getAmountOnHand|getAmountOnHand[\s\S]{0,400}setAmountOnHand' "$V_DTO"
run V-B2 "ClubLineSkuDto still exposes amountAvailable (contract kept)" \
    has 'getAmountAvailable' "$V_DTO"

# ---- Fix D: the three UI surfaces ---------------------------------------------------------------
echo
echo "Fix D — three surfaces gain a column; headers and gates unchanged"

run V-D1a "transferPicking binds amountOnHand"  has "amountOnHand" "$V_UI_TRANSFER"
run V-D1b "clubRuns binds amountOnHand"         has "amountOnHand" "$V_UI_CLUB"
run V-D1c "outbound transfer binds amountOnHand" has "amountOnHand" "$V_UI_OUTBOUND"

# R1/AC6 — the Run gate's comparison must still read the LANE figure in all three.
run V-D2a "transferPicking gate still compares amountAvailable (R1/AC6)" \
    has 'amountAvailable >= item\.amountRequired|amountAvailable >= this\.amountRequired' "$V_UI_TRANSFER"
# ⚠ V-D2b was `has 'amountAvailable' "$V_UI_CLUB"` — VACUOUS. That string occurs four times in
#   clubRuns/itemsTable.vue and only ONE is the gate; the others are the header binding at :101, a data
#   reference, and — ironically — the explanatory comment THIS TICKET ADDED at :107. So repointing BOTH
#   disableRun and showBadge at amountOnHand would have left the row green, and this is the club half of
#   the mitigation the plan names four times for R1 (Critical). Caught by the Phase 3b code review.
#   Now pins the two gate expressions SEPARATELY and by their actual operators.
run V-D2b "clubRuns disableRun still compares amountAvailable with < (R1/AC6)" \
    has 'itemInfo\[i\]\.amountAvailable < this\.itemInfo\[i\]\.amountRequired' "$V_UI_CLUB"
run V-D2d "clubRuns showBadge still compares amountAvailable with >= (R1/AC6)" \
    has 'item\.amountAvailable >= item\.amountRequired' "$V_UI_CLUB"
run V-D2c "outbound badge still compares amountAvailable" \
    has 'amountAvailable >= item\.amountRequired' "$V_UI_OUTBOUND"

# R6/D3' — the relabel was CANCELLED. The existing headers must survive verbatim.
run V-D3a "transferPicking header still reads 'Qty at Lane' (D3')" \
    has "text: 'Qty at Lane'" "$V_UI_TRANSFER"
run V-D3b "outbound transfer header still reads 'Qty at Lane' (D3')" \
    has "text: 'Qty at Lane'" "$V_UI_OUTBOUND"
run V-D4  "clubRuns header still reads 'Total at Lane' (D3')" \
    has "text: 'Total at Lane'" "$V_UI_CLUB"

run V-D5a "no 'Staged' header introduced in transferPicking (R6)" \
    lacks_code "text: 'Staged" "$V_UI_TRANSFER"
run V-D5b "no 'Staged' header introduced in clubRuns (R6)" \
    lacks_code "text: 'Staged" "$V_UI_CLUB"
run V-D5c "no 'Staged' header introduced in outbound transfer (R6)" \
    lacks_code "text: 'Staged" "$V_UI_OUTBOUND"

# ---- Cross-cutting negatives --------------------------------------------------------------------
echo
echo "Cross-cutting"

# Critic MJ1 — the constant already exists; adding a second is a compile error.
run V-X1 "exactly one STORAGE_LOCATION_SHIPPED assignment in WmsConstants (MJ1)" \
    count_is 'STORAGE_LOCATION_SHIPPED *=' "$V_CONSTANTS" 1

# R2b/D6' — this ticket is decoupled from SBDEV-2952. UnitloadRepository must stay out of it.
run V-X2 "UnitloadRepository carries no on-hand code (R2b/D6')" \
    lacks_code 'sumOnHand|OnHandView' "$V_UNITLOADREPO"

# ---- Test lane ----------------------------------------------------------------------------------
echo
echo "Tests"
mvn_test_passes() {
    local cls=$1
    ( cd "$PROJECT_ROOT/v2/wms2-api" \
      && PATH="$HOME/.sdkman/candidates/maven/current/bin:$HOME/.sdkman/candidates/java/current/bin:$PATH" \
         mvn -q -o test -Dtest="$cls" -DfailIfNoTests=true ) >/dev/null 2>&1
}
# ⚠ V-T2 originally named `OnHandExportUnitTest`, a class that was never created — the TDD gate folded its
#   two export assertions into OnHandQueryContractUnitTest (which also carries five more) and nobody
#   reconciled this row. `mvn_test_passes` uses -DfailIfNoTests=true, so the row was PERMANENTLY RED: it
#   failed identically whether the code was perfect or absent, i.e. it asserted nothing while looking like
#   an honest failure. Caught by the Phase 3a conformance lane. Repointed at the class that actually holds
#   the assertions — that strengthens the row rather than weakening it.
if [ "${VERIFY_RUN_TESTS:-0}" = "1" ]; then
    run V-T1 "OnHandQuantityServiceUnitTest passes"  mvn_test_passes OnHandQuantityServiceUnitTest
    run V-T2 "OnHandQueryContractUnitTest passes (HAL export + SQL text, both directions)" \
        mvn_test_passes OnHandQueryContractUnitTest
    run V-T3 "ClubLineSkuDtoOnHandContractUnitTest passes" \
        mvn_test_passes ClubLineSkuDtoOnHandContractUnitTest
else
    printf "  SKIP  %-8s  %s\n" "V-T1" "OnHandQuantityServiceUnitTest (set VERIFY_RUN_TESTS=1)"
    printf "  SKIP  %-8s  %s\n" "V-T2" "OnHandQueryContractUnitTest (set VERIFY_RUN_TESTS=1)"
    printf "  SKIP  %-8s  %s\n" "V-T3" "ClubLineSkuDtoOnHandContractUnitTest (set VERIFY_RUN_TESTS=1)"
    SKIP=$((SKIP+3))
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
