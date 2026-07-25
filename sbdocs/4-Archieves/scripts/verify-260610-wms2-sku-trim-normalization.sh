#!/usr/bin/env bash
# verify-260610-wms2-sku-trim-normalization.sh — machine-checkable acceptance for
# "WMS2 SKU Trim Normalization" (replaces closed PR #14 / FreeScout #959).
#
# Plan: sbdocs/1-Projects/wms2/plan/260610-wms2-sku-trim-normalization.md
# Phase 2 (data cleanup) is runbook-gated and NOT checked here; its acceptance is
# the per-tenant discovery query returning 0 untrimmed rows for both columns.
#
#   $ bash sbdocs/9-System/scripts/verify-260610-wms2-sku-trim-normalization.sh
#   $ RUN_MVN=1 bash ...   # additionally run the targeted JUnit suites (slow)

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

RUN_MVN="${RUN_MVN:-0}"
MAIN=src/main/java/net/aim_ai/wms

PASS=0; FAIL=0; SKIP=0
run() { local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then printf "  PASS  %-12s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else printf "  FAIL  %-12s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi; }
skip() { printf "  SKIP  %-12s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }
file_contains() { grep -qE "$1" "$2"; }
file_contains_n() { [ "$(grep -cE "$1" "$2" 2>/dev/null || echo 0)" -ge "$3" ]; }
file_not_contains() { [ -f "$2" ] && ! grep -qE "$1" "$2"; }
mvn_test_passes() { mvn test -Dtest="$1" -DfailIfNoTests=false -q 2>&1 | grep -qE "BUILD SUCCESS"; }

SKU_CTRL="$MAIN/controller/rest/SkuRestController.java"
ITEM_SVC="$MAIN/service/ItemdataService.java"
FILE_IMP="$MAIN/controller/FileImportController.java"
UPSERT="$MAIN/service/SkuBatchCreateUpdateService.java"
ITEM_CTRL="$MAIN/controller/ItemDataController.java"

# --- Phase 1: write-boundary + choke-point normalization ---
check_normalize_exists() { file_contains 'private static void normalize\(SkuDto' "$SKU_CTRL"; }
check_normalize_called_3x() { file_contains_n 'normalize\(sku\)' "$SKU_CTRL" 3; }
check_lookup_trim() {
    # findByClientIdAndItemNr trims its itemNr argument (null-safe)
    awk '/Optional<Itemdata> findByClientIdAndItemNr/,/^    }/' "$ITEM_SVC" | grep -qE '\.trim\(\)'
}
check_fileimport_trim() {
    # SkuUploadDto skuNumber/skuName trimmed in importSkus
    awk '/importSkus/,/^    }$/' "$FILE_IMP" | grep -qE 'getSkuNumber\(\)\.trim\(\)|getSkuName\(\)\.trim\(\)|\.trim\(\)'
}
# --- Phase 1b: second lookup boundary ---
check_loaditemset_trim() {
    awk '/loadItemDataSet/,/^    }$/' "$ITEM_SVC" | grep -qE '\.trim\(\)'
}
# --- Negative checks: single normalization point, no unnecessary edits ---
check_no_trim_in_upsert() { file_not_contains '\.trim\(\)' "$UPSERT"; }
check_no_edit_itemdatacontroller() {
    # ItemDataController:191 lookup is covered transitively — no trim edit there
    file_not_contains '\.trim\(\)' "$ITEM_CTRL"
}

echo
echo "verify-260610-wms2-sku-trim-normalization — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo
echo "Phase 1 — normalization"
run P1-norm      "normalize(SkuDto) helper exists in SkuRestController"          check_normalize_exists
run P1-norm3     "normalize() called in create/update/delete loops (>=3)"        check_normalize_called_3x
run P1-lookup    "findByClientIdAndItemNr trims its itemNr argument"             check_lookup_trim
run P1-fileimp   "importSkus trims SkuUploadDto skuNumber/skuName"               check_fileimport_trim
echo
echo "Phase 1b — set-lookup boundary (sequencing-gated per plan §5)"
run P1b-set      "loadItemDataSet trims skuSet/.equals input"                    check_loaditemset_trim
echo
echo "Negative checks"
run N-upsert     "no trim inside upsertAll (single normalization point)"         check_no_trim_in_upsert
run N-itemctrl   "no edit in ItemDataController (:191 covered transitively)"     check_no_edit_itemdatacontroller
echo
if [ "$RUN_MVN" = "1" ]; then
    run MVN "SkuRestControllerUnitTest + ItemdataService tests pass" mvn_test_passes "SkuRestControllerUnitTest,ItemdataServiceUnitTest"
else
    skip MVN "targeted suites pass" "set RUN_MVN=1 to execute"
fi
echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
