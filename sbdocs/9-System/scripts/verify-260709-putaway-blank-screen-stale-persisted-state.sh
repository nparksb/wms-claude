#!/usr/bin/env bash
# verify-260709-putaway-blank-screen-stale-persisted-state.sh
# Machine-checkable acceptance for the Putaway blank-screen fix
# (stale persisted Vuex state + unguarded derefs).
#
# Plan: sbdocs/1-Projects/wms1/plan/260709-putaway-blank-screen-stale-persisted-state.md
#
# Run:
#   PROJECT_ROOT=/home/nampark/dev/wms-claude/v1/wms-mobile-ui \
#     bash sbdocs/9-System/scripts/verify-260709-putaway-blank-screen-stale-persisted-state.sh
#
# Exit 0 iff all checks pass. Paste output into the end-of-task report.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v1/wms-mobile-ui}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    local id=$1 desc=$2 reason=$3
    printf "  SKIP  %-10s  %s  (%s)\n" "$id" "$desc" "$reason"; SKIP=$((SKIP+1))
}

# --- assertion helpers ---
file_contains()      { grep -qE "$1" "$2"; }
file_not_contains()  { ! grep -qE "$1" "$2"; }

PUTAWAY_PAGE="pages/putaway.vue"
PUTAWAY_STORE="store/putaway.js"
SCANFLOWBIN="components/putaway/scanFlowBin.vue"
STOREBOX="components/putaway/storeBox.vue"

# === F1 — pages/putaway.vue created()/mounted() reset ========================
# Accept EITHER created() (preferred — runs before child render, review M-1) or mounted().
check_F1_reset_hook()        { file_contains '(created|mounted)\s*\(\s*\)\s*\{' "$PUTAWAY_PAGE"; }
check_F1_commits_reset()     { file_contains "putaway/resetState" "$PUTAWAY_PAGE"; }

# === F2 — store/putaway.js resetState mutation ===============================
check_F2_resetState_present(){ file_contains 'resetState\s*\(\s*state\s*\)\s*\{' "$PUTAWAY_STORE"; }
check_F2_resetState_process(){ file_contains "state\.process\s*=\s*'1_select'" "$PUTAWAY_STORE"; }
check_F2_resetState_info()   { file_contains 'state\.putawayInfo\s*=\s*null' "$PUTAWAY_STORE"; }

# === F3 — store/putaway.js setCurrentIndex null-safe =========================
# POSITIVE: setCurrentIndex now uses optional chaining on putawayInfo.
check_F3_setidx_nullsafe()   { file_contains 'state\.currentItem\s*=\s*state\.putawayInfo\?\.' "$PUTAWAY_STORE"; }
# NEGATIVE: the old unguarded form is gone.
check_F3_old_deref_gone()    { file_not_contains 'state\.currentItem\s*=\s*state\.putawayInfo\.putAwayItemDataList\[payload\]' "$PUTAWAY_STORE"; }

# === F4 — scanFlowBin.vue guards ============================================
# POSITIVE: putawayItems computed guarded with ?. and || [] fallback.
check_F4_computed_guarded()  { file_contains 'putawayInfo\?\.putAwayItemDataList\s*\|\|\s*\[\]' "$SCANFLOWBIN"; }
# POSITIVE: idx derefs use optional chaining.
check_F4_idx_optional()      { file_contains 'putAwayItemDataList\[currentIndex\]\?\.' "$SCANFLOWBIN"; }
# NEGATIVE: old unguarded computed deref gone.
check_F4_old_computed_gone() { file_not_contains 'return this\.\$store\.state\.putaway\.putawayInfo\.putAwayItemDataList' "$SCANFLOWBIN"; }
# NEGATIVE: old unguarded template idx derefs gone (unitLoadList / join without ?.).
check_F4_old_unitload_gone() { file_not_contains 'putAwayItemDataList\[currentIndex\]\.unitLoadList\.length' "$SCANFLOWBIN"; }
check_F4_old_join_gone()     { file_not_contains 'putAwayItemDataList\[currentIndex\]\.(flowBinLocationList|overstockLocationList)\.join' "$SCANFLOWBIN"; }
# F4 (M-1): line-17 emptyPallet deref, OUTSIDE the v-if="info" block, must be guarded.
# POSITIVE: guarded form present. NEGATIVE: bare v-if="info.emptyPallet" gone.
check_F4_emptypallet_guarded(){ file_contains 'v-if="info && info\.emptyPallet"' "$SCANFLOWBIN"; }
check_F4_emptypallet_old_gone(){ file_not_contains 'v-if="info\.emptyPallet"' "$SCANFLOWBIN"; }

# === F5 — storeBox.vue guards (lines 8-10) ==================================
# POSITIVE: idx derefs use optional chaining (all three fields).
check_F5_idx_optional()      { file_contains 'info\?\.putAwayItemDataList\?\.\[currentIndex\]\?\.itemDataNumber' "$STOREBOX"; }
# NEGATIVE: old unguarded forms gone — all three fields (m-2), not just itemDataNumber.
check_F5_old_sku_gone()      { file_not_contains 'info\.putAwayItemDataList\[currentIndex\]\.itemDataNumber' "$STOREBOX"; }
check_F5_old_client_gone()   { file_not_contains 'info\.putAwayItemDataList\[currentIndex\]\.clientName' "$STOREBOX"; }
check_F5_old_name_gone()     { file_not_contains 'info\.putAwayItemDataList\[currentIndex\]\.itemDataName' "$STOREBOX"; }

echo
echo "verify-260709-putaway-blank-screen-stale-persisted-state — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

run F1a  "putaway.vue has created()/mounted() reset hook" check_F1_reset_hook
run F1b  "putaway.vue hook commits putaway/resetState"    check_F1_commits_reset
echo
run F2a  "store: resetState mutation present"             check_F2_resetState_present
run F2b  "store: resetState sets process '1_select'"      check_F2_resetState_process
run F2c  "store: resetState nulls putawayInfo"            check_F2_resetState_info
echo
run F3a  "store: setCurrentIndex uses optional chaining"  check_F3_setidx_nullsafe
run F3b  "store: old unguarded setCurrentIndex deref gone" check_F3_old_deref_gone
echo
run F4a  "scanFlowBin: putawayItems computed guarded"     check_F4_computed_guarded
run F4b  "scanFlowBin: idx derefs use ?."                 check_F4_idx_optional
run F4c  "scanFlowBin: old computed deref gone"           check_F4_old_computed_gone
run F4d  "scanFlowBin: old unitLoadList.length deref gone" check_F4_old_unitload_gone
run F4e  "scanFlowBin: old .join deref gone"              check_F4_old_join_gone
run F4f  "scanFlowBin: line-17 emptyPallet guarded (M-1)" check_F4_emptypallet_guarded
run F4g  "scanFlowBin: bare v-if=info.emptyPallet gone"   check_F4_emptypallet_old_gone
echo
run F5a  "storeBox: idx derefs use ?."                    check_F5_idx_optional
run F5b  "storeBox: old SKU deref gone"                   check_F5_old_sku_gone
run F5c  "storeBox: old clientName deref gone"            check_F5_old_client_gone
run F5d  "storeBox: old itemDataName deref gone"          check_F5_old_name_gone

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
