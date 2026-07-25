#!/usr/bin/env bash
# verify-SBDEV-2486-club-lane-blank-screen-split-adjust.sh
# Machine-checkable acceptance for SBDEV-2486 — Club Lane Screen Goes Blank After Split + Quantity Adjust (v1)
#
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2486-club-lane-blank-screen-split-adjust.sh
#
# Checks span TWO repos (v1/wms-api + v1/wms-web-ui), so paths are computed
# from the monorepo root rather than a single PROJECT_ROOT.

set -u

MONOREPO_ROOT="${MONOREPO_ROOT:-/home/nampark/dev/wms-claude}"
API_ROOT="${API_ROOT:-$MONOREPO_ROOT/v1/wms-api}"
WEB_ROOT="${WEB_ROOT:-$MONOREPO_ROOT/v1/wms-web-ui}"

SVC="$API_ROOT/src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java"
STORE="$WEB_ROOT/store/processes/clubRuns.js"
DETAILS="$WEB_ROOT/components/processes/clubRuns/clubRunDetails.vue"
INV_TABLE="$WEB_ROOT/components/processes/clubRuns/tabTables/inventoryOnLaneTable.vue"
AVAIL_TABLE="$WEB_ROOT/components/processes/clubRuns/tabTables/availableInventory.vue"
PARCEL_TABLE="$WEB_ROOT/components/processes/clubRuns/tabTables/parcelsClubBatchTable.vue"
ITEMS_TABLE="$WEB_ROOT/components/processes/clubRuns/itemsTable.vue"

for f in "$SVC" "$STORE" "$DETAILS" "$INV_TABLE" "$AVAIL_TABLE" "$PARCEL_TABLE" "$ITEMS_TABLE"; do
    [ -f "$f" ] || { echo "FATAL: expected file not found: $f"; exit 2; }
done

PASS=0; FAIL=0; SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}
skip() { printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

file_contains()     { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }
file_contains_n_times() {
    local pattern=$1 file=$2 n=$3 count
    count=$(grep -cE "$pattern" "$file" 2>/dev/null || echo 0)
    [ "$count" -ge "$n" ]
}
# Assert a `catch (...) { ... }` block in $2 contains pattern $1. These catch
# bodies have no nested braces, so [^}]* safely spans to the block's close.
# Discriminates the F1 fix from the pre-existing success-path commit: pre-fix
# the reset is NOT inside any catch block, so this fails (unlike a file-wide grep).
file_catch_contains() {
    grep -Pzoq "catch\s*\([^)]*\)\s*\{[^}]*$1[^}]*\}" "$2"
}
mvn_test_passes() {
    ( cd "$API_ROOT" && mvn test -Dtest="$1" -DfailIfNoTests=false -q 2>&1 \
        | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0" )
}

# === Backend checks ===========================================================

# B1 — itemdata orElseThrow + itemunit null-safe; old raw deref gone; forEach lambda gone
check_B1_itemdata_orelsethrow() {
    file_contains 'findById\(position\.getItemdataId\(\)\)' "$SVC" &&
    file_contains 'orElseThrow\(\s*\(\)\s*->\s*new BusinessException\("Itemdata not found' "$SVC"
}
check_B1_itemunit_null_safe() {
    file_contains '\.map\(Itemunit::getUnitname\)' "$SVC"
}
check_B1_old_deref_gone() {
    file_not_contains 'orElse\(null\)\.getUnitname\(\)' "$SVC"
}
check_B1_foreach_gone() {
    # the forEach lambda must be converted to an enhanced for-loop so a checked
    # BusinessException can propagate; assert no positions.forEach( remains
    file_not_contains 'positions\.forEach\(' "$SVC"
}

# B2 — id-based filter, null-safe amount; old reference-equality filter gone
check_B2_id_filter() {
    file_contains 'itemData\.getId\(\)\.equals\(su\.getItemdataId\(\)\)' "$SVC"
}
check_B2_null_safe_amount() {
    file_contains 'su\.getAmount\(\)\s*==\s*null\s*\?\s*0\s*:\s*su\.getAmount\(\)\.intValue\(\)' "$SVC"
}
check_B2_old_ref_equality_gone() {
    file_not_contains 'itemData\.equals\(itemDataMap\.get\(su\.getItemdataId\(\)\)\)' "$SVC"
}

# B3 — ifPresent client guard; old orElse(null) client deref gone
check_B3_ifpresent() {
    file_contains 'findById\(cob\.getClientId\(\)\)\.ifPresent\(' "$SVC"
}
check_B3_old_client_deref_gone() {
    file_not_contains 'Client client = clientRepository\.findById\(cob\.getClientId\(\)\)\.orElse\(null\)' "$SVC"
}

# B4 — null-guarded SKU filter predicate; old unguarded form gone
check_B4_null_guard() {
    file_contains 'id\s*!=\s*null\s*&&\s*skuFilter\.equals\(id\.getName\(\)\)' "$SVC"
}
check_B4_old_unguarded_gone() {
    file_not_contains 'skuFilter\.equals\(itemDataMap\.get\(pos\.getItemdataId\(\)\)\.getName\(\)\)' "$SVC"
}

# === Frontend checks ==========================================================

# F1 — each loading-reset commit present INSIDE a catch block (not just the
# pre-existing success-path commit); plus each flag set false >=2x (success + catch).
check_F1_inventory_reset()  { file_catch_contains "setInventoryOnLaneLoading[\"'], *false" "$STORE"; }
check_F1_available_reset()  { file_catch_contains "setAvailableInventoryLoading[\"'], *false" "$STORE"; }
check_F1_parcels_reset()    { file_catch_contains "setParcelsClubBatchLoading[\"'], *false" "$STORE"; }
check_F1_inventory_twice()  { file_contains_n_times "setInventoryOnLaneLoading[\"'], *false" "$STORE" 2; }
check_F1_available_twice()  { file_contains_n_times "setAvailableInventoryLoading[\"'], *false" "$STORE" 2; }
check_F1_parcels_twice()    { file_contains_n_times "setParcelsClubBatchLoading[\"'], *false" "$STORE" 2; }

# F2 — self-heal dispatch, rejection-safe (async/try), and guarded commit
check_F2_selfheal_dispatch() {
    file_contains "getClubRunFullDetails" "$DETAILS" &&
    file_contains "setClubRunDetails" "$DETAILS"
}
check_F2_rejection_safe() {
    # initialize() must be async and the self-heal await must be try/catch wrapped
    file_contains 'async initialize\s*\(' "$DETAILS" &&
    file_contains '\btry\b' "$DETAILS"
}
check_F2_guarded_commit() {
    file_contains 'details && !details\.errors && details\.id' "$DETAILS"
}
check_F2_null_guard() {
    file_contains 'if\s*\(!this\.clubRunDetails\)' "$DETAILS"
}

# F3 — Array.isArray guard in all four tab computeds (defensive)
check_F3_inventory()  { file_contains 'Array\.isArray\(hasKey\)' "$INV_TABLE"; }
check_F3_available()  { file_contains 'Array\.isArray\(hasKey\)' "$AVAIL_TABLE"; }
check_F3_parcels()    { file_contains 'Array\.isArray\(hasKey\)' "$PARCEL_TABLE"; }
check_F3_items()      { file_contains 'Array\.isArray\(hasKey\)' "$ITEMS_TABLE"; }

# F4 — getItemInfo resets itemInfo to [] on error
check_F4_reset_iteminfo() {
    file_contains "setItemInfo', \[\]" "$STORE"
}

# === Wire into the runner =====================================================

echo
echo "verify-SBDEV-2486 — running acceptance checks"
echo "  MONOREPO_ROOT=$MONOREPO_ROOT"
echo

run B1a  "B1 — itemdata orElseThrow(BusinessException)"      check_B1_itemdata_orelsethrow
run B1b  "B1 — itemunit null-safe .map(getUnitname)"          check_B1_itemunit_null_safe
run B1c  "B1 — old orElse(null).getUnitname() removed"        check_B1_old_deref_gone
run B1d  "B1 — positions.forEach( lambda converted to for"    check_B1_foreach_gone
echo
run B2a  "B2 — id-based filter getId().equals(getItemdataId)" check_B2_id_filter
run B2b  "B2 — null-safe amount (==null?0:...)"               check_B2_null_safe_amount
run B2c  "B2 — old reference-equality filter removed"         check_B2_old_ref_equality_gone
echo
run B3a  "B3 — clientRepository.findById(...).ifPresent"      check_B3_ifpresent
run B3b  "B3 — old orElse(null) client deref removed"         check_B3_old_client_deref_gone
echo
run B4a  "B4 — SKU filter null-guard"                         check_B4_null_guard
run B4b  "B4 — old unguarded SKU filter removed"              check_B4_old_unguarded_gone
echo
run F1a  "F1 — getInventoryOnLane catch-block resets loading" check_F1_inventory_reset
run F1b  "F1 — getAvailableInventory catch-block resets loading" check_F1_available_reset
run F1c  "F1 — getParcelsClubBatch catch-block resets loading" check_F1_parcels_reset
run F1d  "F1 — inventory loading set false >=2x"              check_F1_inventory_twice
run F1e  "F1 — available loading set false >=2x"              check_F1_available_twice
run F1f  "F1 — parcels loading set false >=2x"                check_F1_parcels_twice
echo
run F2a  "F2 — initialize self-heals via getClubRunFullDetails" check_F2_selfheal_dispatch
run F2b  "F2 — initialize is async + try/catch (rejection-safe)" check_F2_rejection_safe
run F2c  "F2 — guarded commit (details && !errors && id)"     check_F2_guarded_commit
run F2d  "F2 — null clubRunDetails guard present"             check_F2_null_guard
echo
run F3a  "F3 — inventoryOnLaneTable Array.isArray guard"      check_F3_inventory
run F3b  "F3 — availableInventory Array.isArray guard"        check_F3_available
run F3c  "F3 — parcelsClubBatchTable Array.isArray guard"     check_F3_parcels
run F3d  "F3 — itemsTable Array.isArray guard"                check_F3_items
echo
run F4a  "F4 — getItemInfo resets itemInfo on error"          check_F4_reset_iteminfo
echo

# === Optional targeted tests (uncomment once test classes exist) ==============
# run B-test1 "CustomerorderBatchServiceUnitTest passes" mvn_test_passes CustomerorderBatchServiceUnitTest
# run B-test2 "ClubLineControllerIT passes"              mvn_test_passes ClubLineControllerIT
skip B-test1 "CustomerorderBatchServiceUnitTest" "test class proposed, not yet created"
skip B-test2 "ClubLineControllerIT"              "test class proposed, not yet created"

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
