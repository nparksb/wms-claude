#!/usr/bin/env bash
# verify-SBDEV-2496-prshw222-trailing-space-sku-duplication.sh
# Machine-checkable acceptance for SBDEV-2496 — trailing-space SKU duplication fix.
#
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2496-prshw222-trailing-space-sku-duplication.sh
#
# Exit 0 iff all checks pass. Paste the "Result:" line into the end-of-task report.
# Override the project root if your checkout differs:
#   PROJECT_ROOT=/path/to/v1/wms-api bash .../verify-SBDEV-2496-....sh

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v1/wms-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0
run() { local id=$1 desc=$2; shift 2; if "$@" >/dev/null 2>&1; then printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1)); else printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi; }
skip() { printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

file_contains()      { grep -qE "$1" "$2"; }
file_not_contains()  { ! grep -qE "$1" "$2"; }
file_exists()        { [ -f "$1" ]; }
file_contains_n_times() { local c; c=$(grep -cE "$1" "$2" 2>/dev/null); [ "${c:-0}" -ge "$3" ]; }
mvn_test_passes()    { mvn test -Dtest="$1" -DfailIfNoTests=false -q 2>&1 | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0"; }

SRC=src/main/java/net/aim_ai/wms
SKU=$SRC/controller/rest/SkuRestController.java
FILEIMP=$SRC/controller/FileImportController.java
ORDER=$SRC/controller/rest/OrderRestController.java
ADVICE=$SRC/controller/rest/AdviceRestController.java
ITEMDATA=$SRC/model/Itemdata.java

# --- S1: SkuCodes helper exists with a normalize method ---
check_S1_helper_exists() {
    local f
    f=$(grep -rl "class SkuCodes" "$SRC" 2>/dev/null | head -1)
    [ -n "$f" ] && file_contains "static[[:space:]]+String[[:space:]]+normalize[[:space:]]*\(" "$f"
}

# --- S2: Itemdata.setItemNr trims (Fix A) ---
check_S2_setter_trims() {
    # setItemNr is the only place that trims itemNr (getItemNr just returns it)
    file_contains "itemNr\.trim\(\)" "$ITEMDATA"
}

# --- S3: SkuRestController normalizes lookup + persist; raw setItemNr(sku.getSku()) gone ---
check_S3_lookup_normalized() {
    # all three findByClientIdAndItemNr calls wrap the inbound sku in SkuCodes.normalize
    # (.* not [^)]* because the first arg client.getId() contains a ')')
    file_contains_n_times "findByClientIdAndItemNr\(.*SkuCodes\.normalize\(" "$SKU" 3
}
check_S3_raw_persist_gone() {
    file_not_contains "setItemNr\([[:space:]]*sku\.getSku\(\)[[:space:]]*\)" "$SKU"
}

# --- S4: FileImportController persist normalized ---
check_S4_fileimport_normalized() {
    # FileImport computes normalizedSkuNumber = SkuCodes.normalize(skuDto.getSkuNumber()) and persists it
    file_contains "SkuCodes\.normalize\(skuDto\.getSkuNumber\(\)\)" "$FILEIMP"
}
check_S4_fileimport_raw_gone() {
    file_not_contains "setItemNr\([[:space:]]*skuDto\.getSkuNumber\(\)[[:space:]]*\)" "$FILEIMP"
}

# --- S5: OrderRestController + AdviceRestController normalize inbound SKU ---
# NOTE: a bare presence-grep passes on a half-done job. We require normalize to
# appear at least twice in OrderRestController (set-build AND bind/map), assert
# the raw unguarded bind is gone, and lean on the behavioral test (S5-test) as
# the real proof of consistent normalization.
check_S5_order_normalized() {
    file_contains_n_times "SkuCodes\.normalize\(" "$ORDER" 2
}
check_S5_order_raw_bind_gone() {
    # the raw bind 'get(orderPosition.getSkuId())' must be replaced by a normalized key
    file_not_contains "\.get\([[:space:]]*orderPosition\.getSkuId\(\)[[:space:]]*\)" "$ORDER"
}
check_S5_order_null_guard() {
    # the new null guard before itemData.getId() at the bind site (:435/:443).
    # 'ENTITY_DOES_NOT_EXISTS' already appears in resolveItemData, so assert the
    # specific new construct instead: an explicit itemData null check (absent today).
    file_contains "itemData[[:space:]]*==[[:space:]]*null" "$ORDER"
}
check_S5_advice_normalized() {
    file_contains "SkuCodes\.normalize\(" "$ADVICE"
}

# --- S6: Flyway migration present and guarded ---
# Version must continue from actual Flyway head (V1.26.30 as of 2026-06-26), NOT V1.1.x
# (V1.1.06 already exists). Match by description so a head bump (V1.26.32+) still passes.
S6_MIG=$(ls src/main/resources/db/migration/V*__trim_itemdata_item_nr_whitespace.sql 2>/dev/null | head -1)
check_S6_migration_exists() {
    [ -n "$S6_MIG" ] && file_exists "$S6_MIG"
}
check_S6_migration_version_not_stale() {
    # reject the stale V1.1.x naming; require V1.26.x or higher minor
    [ -n "$S6_MIG" ] && echo "$S6_MIG" | grep -qE "/V1\.(2[6-9]|[3-9][0-9])\."
}
check_S6_migration_trims() {
    # whitespace-trim that matches Java String.trim() (regexp_replace with \s), not btrim
    [ -n "$S6_MIG" ] && file_contains "regexp_replace\(.*item_nr.*\)" "$S6_MIG"
}
check_S6_migration_collision_guard() {
    [ -n "$S6_MIG" ] && file_contains "NOT[[:space:]]+EXISTS" "$S6_MIG"
}

echo
echo "verify-SBDEV-2496 — running acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

run S1   "S1  — SkuCodes.normalize helper exists"                 check_S1_helper_exists
run S2   "S2  — Itemdata.setItemNr trims whitespace"              check_S2_setter_trims
run S3   "S3  — SkuRest lookups normalized"                       check_S3_lookup_normalized
run S3b  "S3  — raw setItemNr(sku.getSku()) removed"              check_S3_raw_persist_gone
run S4   "S4  — FileImport persist normalized"                    check_S4_fileimport_normalized
run S4b  "S4  — raw setItemNr(skuDto.getSkuNumber()) removed"     check_S4_fileimport_raw_gone
run S5   "S5  — OrderRest normalize at >=2 sites (set+bind)"      check_S5_order_normalized
run S5b  "S5  — OrderRest raw getSkuId() bind replaced"           check_S5_order_raw_bind_gone
run S5c  "S5  — OrderRest has ENTITY_DOES_NOT_EXISTS guard"       check_S5_order_null_guard
run S5d  "S5  — AdviceRest inbound SKU normalized"                check_S5_advice_normalized
run S6   "S6  — trim migration present (V1.26.x+)"                check_S6_migration_exists
run S6b  "S6  — migration version not stale (not V1.1.x)"         check_S6_migration_version_not_stale
run S6c  "S6  — migration trims item_nr"                          check_S6_migration_trims
run S6d  "S6  — migration has collision guard"                    check_S6_migration_collision_guard

echo
# Behavioral proof — a code-shape grep proves the call exists, NOT that normalization
# is consistent across set-build/bind/map. Enable these once tests are authored; the
# OrderRestControllerTest row is the real gate for S5 consistency.
# run S1-t "S1  unit test passes"      mvn_test_passes SkuCodesTest
# run S2-t "S2  hydration IT passes"   mvn_test_passes ItemdataHydrationIT
# run S3-t "S3  controller test"       mvn_test_passes SkuRestControllerTest
# run S5-t "S5  order import test"     mvn_test_passes OrderRestControllerTest
skip S-test "targeted mvn tests (incl. OrderRestControllerTest — real S5 gate)" "enable after tests are authored"

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
