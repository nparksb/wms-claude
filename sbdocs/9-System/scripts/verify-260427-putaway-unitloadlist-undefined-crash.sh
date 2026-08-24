#!/usr/bin/env bash
# verify-260427-putaway-unitloadlist-undefined-crash.sh
#
# Acceptance script for plan:
#   260427-putaway-unitloadlist-undefined-crash.md
#
# Checks code-shape assertions for each fix (A–E) in wms-mobile-ui.
# Run after every implementation pass:
#
#   $ bash sbdocs/9-System/scripts/verify-260427-putaway-unitloadlist-undefined-crash.sh
#
# Exit 0 only when every active check passes.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v1/wms-mobile-ui}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-14s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-14s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    printf "  SKIP  %-14s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1))
}

file_contains()     { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2" 2>/dev/null; }

STORE=store/putaway.js
FLOWBIN=components/putaway/scanFlowBin.vue
STOREBOX=components/putaway/storeBox.vue

echo
echo "verify-260427-putaway-unitloadlist-undefined-crash"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# ===========================================================================
# Fix A — calculatePutawayList and scanPallet reset currentIndex to 0
# ===========================================================================
echo "── Fix A: currentIndex reset in store actions ───────────────────────────"
echo

run FA-1-pos "calculatePutawayList commits setCurrentIndex after setPutawayInfo" \
    file_contains "commit\('setCurrentIndex',\s*0\)" "$STORE"

run FA-1-neg "calculatePutawayList no longer missing index reset (smell: setProcess 3_flowbin after setPutawayInfo without setCurrentIndex)" \
    file_not_contains "commit\('setPutawayInfo',\s*result\)[^}]*commit\('setProcess',\s*'3_flowbin'\)" "$STORE"

run FA-2-pos "setCurrentIndex mutation has defensive guard (idx fallback)" \
    file_contains "payload !== undefined" "$STORE"

run FA-2-neg "setCurrentIndex mutation no longer directly assigns undefined payload" \
    file_not_contains "state\.currentIndex\s*=\s*payload" "$STORE"

echo

# ===========================================================================
# Fix B — scanFlowBin.vue: currentItemData computed + guarded template
# ===========================================================================
echo "── Fix B: scanFlowBin.vue defensive currentItemData computed ────────────"
echo

run FB-1-pos "scanFlowBin has currentItemData computed property" \
    file_contains "currentItemData\(\)" "$FLOWBIN"

run FB-2-pos "scanFlowBin v-if guards both info and currentItemData" \
    file_contains 'v-if="info && currentItemData"' "$FLOWBIN"

run FB-3-neg "scanFlowBin no bare putAwayItemDataList[currentIndex] in template" \
    file_not_contains 'putAwayItemDataList\[currentIndex\]' "$FLOWBIN"

run FB-4-pos "scanFlowBin unitLoadList guarded with ternary in template" \
    file_contains 'currentItemData\.unitLoadList\s*\?' "$FLOWBIN"

echo

# ===========================================================================
# Fix C — storeBox.vue: currentItemData computed + guarded template
# ===========================================================================
echo "── Fix C: storeBox.vue defensive currentItemData computed ───────────────"
echo

run FC-1-pos "storeBox has currentItemData computed property" \
    file_contains "currentItemData\(\)" "$STOREBOX"

run FC-2-pos "storeBox v-if guards both info and currentItemData" \
    file_contains 'v-if="info && currentItemData"' "$STOREBOX"

run FC-3-neg "storeBox no bare putAwayItemDataList[currentIndex] in template" \
    file_not_contains 'putAwayItemDataList\[currentIndex\]' "$STOREBOX"

run FC-4-pos "storeBox unitLoadList guarded with ternary for length" \
    file_contains 'currentItemData\.unitLoadList\s*\?.*length' "$STOREBOX"

run FC-5-pos "storeBox unitLoadList guarded with ternary for join" \
    file_contains 'currentItemData\.unitLoadList\s*\?.*join' "$STOREBOX"

echo

# ===========================================================================
# Fix D — scanFlowBin.vue: putawayItems computed null-guard
# ===========================================================================
echo "── Fix D: scanFlowBin.vue putawayItems null guard ───────────────────────"
echo

run FD-1-pos "putawayItems computed guards putawayInfo before accessing putAwayItemDataList" \
    file_contains 'putawayInfo.*putAwayItemDataList|putawayInfo\?\.putAwayItemDataList' "$FLOWBIN"

run FD-1-neg "putawayItems no longer directly chains .putAwayItemDataList without guard" \
    file_not_contains 'putaway\.putawayInfo\.putAwayItemDataList' "$FLOWBIN"

echo

# ===========================================================================
# Fix E — scanFlowBinLocation commits result not data (optional)
# ===========================================================================
echo "── Fix E: scanFlowBinLocation commits result (verify API contract first) ─"
echo

run FE-1-pos "scanFlowBinLocation commits result as putawayInfo" \
    file_contains "commit\('setPutawayInfo',\s*result\)" "$STORE"

run FE-1-neg "scanFlowBinLocation no longer commits request data as putawayInfo" \
    file_not_contains "commit\('setPutawayInfo',\s*data\)" "$STORE"

echo

# ===========================================================================
# Regression guards — patterns that must NOT appear in any putaway component
# ===========================================================================
echo "── Regression: no unguarded putAwayItemDataList[currentIndex] remaining ─"
echo

run RG-1 "storePallet.vue has no unguarded putAwayItemDataList[currentIndex]" \
    file_not_contains 'putAwayItemDataList\[currentIndex\]\.[a-zA-Z]*\.' \
    "components/putaway/storePallet.vue"

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
