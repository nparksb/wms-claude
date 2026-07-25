#!/usr/bin/env bash
# verify-SBDEV-2496-trailing-space-sku-duplication-v2.sh
# Machine-checkable acceptance for SBDEV-2496 (v2 port) — order-import + advice SKU normalization.
# Plan: sbdocs/1-Projects/wms2/plan/SBDEV-2496-prshw222-trailing-space-sku-duplication.md
#
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2496-trailing-space-sku-duplication-v2.sh
#
# Baseline (pre-implementation): all S-checks FAIL. Exit 0 iff all checks pass.
# Override target: PROJECT_ROOT=/path/to/v2/wms2-api bash .../verify-...-v2.sh
#
# NOTE (deliberate inversion vs the v1 script): v2 ships NO Flyway data-trim migration —
# data cleanliness is the wms2-sku-trim-data-cleanup runbook. The NEG check asserts the
# migration does NOT exist.

set -u
PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
DOCS_ROOT="${DOCS_ROOT:-/home/nampark/dev/wms-claude/sbdocs}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0
run()  { local id=$1 desc=$2; shift 2; if "$@" >/dev/null 2>&1; then printf "  PASS  %-6s  %s\n" "$id" "$desc"; PASS=$((PASS+1)); else printf "  FAIL  %-6s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi; }
skip() { printf "  SKIP  %-6s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

SRC=src/main/java/net/aim_ai/wms
SKUCODES=$SRC/util/SkuCodes.java
ORDER=$SRC/controller/rest/OrderRestController.java
BATCH=$SRC/service/OrderBatchCreationService.java
ADVICE=$SRC/controller/rest/AdviceRestController.java
ITEMDATA=$SRC/model/Itemdata.java
FILEIMP=$SRC/controller/FileImportController.java
RUNBOOK=$DOCS_ROOT/2-Areas/runbooks/wms2-sku-trim-data-cleanup.md

# --- S1: SkuCodes helper ---
check_S1()  { [ -f "$SKUCODES" ] && grep -qE "static[[:space:]]+String[[:space:]]+normalize[[:space:]]*\(" "$SKUCODES"; }
# --- S2: Itemdata.setItemNr trims ---
check_S2()  { grep -qE "itemNr\.trim\(\)" "$ITEMDATA"; }
# --- S3: OrderRestController normalized across key spaces ---
check_S3a() { local c; c=$(grep -cE "SkuCodes\.normalize\(|normalizedSku\(" "$ORDER" 2>/dev/null); [ "${c:-0}" -ge 4 ]; }
check_S3b() { ! grep -qE "skuSet\.add\([[:space:]]*orderPosition\.getSkuId\(\)[[:space:]]*\)" "$ORDER"; }
check_S3c() { ! grep -qE "map\.put\([[:space:]]*itemData\.getItemNr\(\)[[:space:]]*," "$ORDER"; }
check_S3d() { ! grep -qE "pos\.getSkuId\(\)\.equals\(candidate\.getSkuId\(\)\)" "$ORDER"; }
# --- S4: OrderBatchCreationService normalized load-bearing bind + null guard ---
check_S4a() { grep -qE "\.get\([[:space:]]*SkuCodes\.normalize\([[:space:]]*orderPosition\.getSkuId\(\)" "$BATCH"; }
check_S4b() { grep -qE "itemData[[:space:]]*==[[:space:]]*null" "$BATCH"; }
# --- S5: AdviceRestController orElseThrow on transfer path ---
check_S5a() { grep -qE "itemDataOptional\.orElseThrow" "$ADVICE"; }
check_S5b() { ! grep -qE "Itemdata[[:space:]]+itemdata[[:space:]]*=[[:space:]]*itemDataOptional\.get\(\)" "$ADVICE"; }
# --- S6: FileImportController advice-import guard ---
#     Baseline defect: unconditional itemData.get() deref right after the miss-only-adds-error-row check.
#     Fixed state: that unconditional deref pattern is gone (guarded/short-circuited).
check_S6()  { ! grep -qE "unitloadTypeRepository\.findById\([[:space:]]*itemData\.get\(\)\.getDefultypeId\(\)" "$FILEIMP"; }
check_S6b() { ! grep -qE "boxtypeRepository\.findById\([[:space:]]*itemData\.get\(\)\.getDefaultboxtypeId\(\)" "$FILEIMP"; }
# --- S7: runbook updated (third gated surface + unique-constraint correction) ---
check_S7a() { grep -q "resolveItemData" "$RUNBOOK"; }
check_S7b() { grep -q "uk3l3dgof3l6mc1dl7s3lmida65" "$RUNBOOK"; }
# --- NEG: no new trim Flyway migration (v2 uses the runbook) ---
check_NEG() { ! ls src/main/resources/db/migration/*trim_itemdata* >/dev/null 2>&1; }
# --- GUARD: persistence-path raw getSkuId() reads in the bind region of OrderBatchCreationService.
#     Legal raw reads: error-message args + audit serialization. The bind .get(...) must be normalized (S4a)
#     and no OTHER raw map-get on getSkuId may appear in either class.
check_GRD() { ! grep -nE "\.get\([[:space:]]*orderPosition\.getSkuId\(\)[[:space:]]*\)" "$BATCH" "$ORDER"; }

echo
echo "verify-SBDEV-2496-v2 — acceptance checks (PROJECT_ROOT=$PROJECT_ROOT)"
echo
run S1  "SkuCodes.normalize helper exists in util/"                    check_S1
run S2  "Itemdata.setItemNr trims"                                     check_S2
run S3a "OrderRest: >=4 normalize/normalizedSku call sites"            check_S3a
run S3b "OrderRest: raw skuSet.add(getSkuId()) removed"                check_S3b
run S3c "OrderRest: raw resolve map key removed"                       check_S3c
run S3d "OrderRest: raw club-line equals removed"                      check_S3d
run S4a "OrderBatch: normalized (load-bearing) bind key"               check_S4a
run S4b "OrderBatch: null guard present"                               check_S4b
run S5a "AdviceRest: orElseThrow on transfer lookup"                   check_S5a
run S5b "AdviceRest: raw itemDataOptional.get() removed"               check_S5b
run S6  "FileImport: unconditional getDefultypeId deref removed"       check_S6
run S6b "FileImport: unconditional getDefaultboxtypeId deref removed"  check_S6b
run S7a "Runbook: resolveItemData listed as gated surface"             check_S7a
run S7b "Runbook: unique-constraint premise corrected"                 check_S7b
run NEG "No new trim Flyway migration (runbook divergence)"            check_NEG
run GRD "No raw .get(getSkuId()) map-read in persistence path"         check_GRD

echo
# mvn rows — enable once the test classes exist (names may be adapted to existing suites):
# mvn_t() { mvn test -Dtest="$1" -DfailIfNoTests=false -q >/dev/null 2>&1; }
# run T1 "SkuCodesUnitTest"                 mvn_t SkuCodesUnitTest
# run T2 "ItemdataUnitTest"                 mvn_t ItemdataUnitTest
# run T3 "OrderRestController unit suite"   mvn_t 'OrderRestController*Test'
# run T4 "OrderBatchCreationService suite"  mvn_t 'OrderBatchCreationService*Test'
# run T5 "AdviceRestController suite"       mvn_t 'AdviceRestController*Test'
# run T6 "FileImportController suite"       mvn_t 'FileImportController*Test'
skip T "targeted mvn test rows" "enable after test classes are authored"

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
