#!/usr/bin/env bash
# verify-SBDEV-2930-mobile-workflow-pages-resume-stale-operator-state.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2930-mobile-workflow-pages-resume-stale-operator-state.md
#
# Target repo: v2/wms2-mobile-ui  (Nuxt 2 / Vue 2)
#
#   PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-mobile-ui \
#     bash sbdocs/9-System/scripts/verify-SBDEV-2930-...-state.sh
#
# Exit 0 only when every check passes.
#
# ---------------------------------------------------------------------------
# ⚠ NEGATIVE-TEST THIS SCRIPT BEFORE TRUSTING IT.
#
# Run it against unmodified origin/develop FIRST. Expected baseline: the A-*,
# B-*, and T-* rows FAIL and the BNEG-*, CTL-*, and GUARD-* rows PASS. A row
# that already passes at baseline is a broken row, not completed work.
# ---------------------------------------------------------------------------
#
# Design notes specific to this script
# ------------------------------------
# 1. Every helper below is FAIL-CLOSED on a missing file. The shared template's
#    `file_not_contains` returns 0 when the file cannot be opened, and its perl
#    multi-line helpers exit 0 when the open fails — so every assertion about a
#    NEW file silently false-greens. Each helper here guards `[ -f ]` first.
#
# 2. The reset must be inside created(), not merely present somewhere in the
#    file. A page with `created() {}` and the commit still in `mounted()` is the
#    exact half-fix this plan exists to prevent, and a whole-file grep cannot
#    see the difference. The B-* rows use a BLOCK-scoped perl match.
#
# 3. Rows are keyed to the plan's §0 table so a stale row is traceable.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-mobile-ui}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-16s  %s\n" "$id" "$desc"
        PASS=$((PASS+1))
    else
        printf "  FAIL  %-16s  %s\n" "$id" "$desc"
        FAIL=$((FAIL+1))
    fi
}

skip() {
    local id=$1 desc=$2 reason=$3
    printf "  SKIP  %-16s  %s  (%s)\n" "$id" "$desc" "$reason"
    SKIP=$((SKIP+1))
}

# --- fail-closed assertion helpers -------------------------------------------

# file_contains <regex> <file>
file_contains() { [ -f "$2" ] || return 1; grep -qE "$1" "$2"; }

# file_not_contains <regex> <file> — FAILS if the file is missing (fail-closed).
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }

# file_contains_ml <perl-regex> <file> — multi-line; fail-closed on missing file.
#
# The pattern is passed through the ENVIRONMENT, not interpolated into the perl
# one-liner. Interpolating it would break on any pattern containing a `/` — and
# every pattern here does ('picking/resetState'), because the `/` closes the
# m/.../ delimiter and silently turns a correct assertion into a red row.
file_contains_ml() {
    [ -f "$2" ] || return 1
    VERIFY_RE="$1" perl -0777 -ne 'exit($_ =~ /$ENV{VERIFY_RE}/s ? 0 : 1)' "$2"
}

# file_not_contains_ml <perl-regex> <file> — multi-line negative; fail-closed.
#
# Needed because grep is LINE-based: a negative assertion about a multi-line
# construct (a commit inside a mounted() block) can never match with grep, so it
# reports "the old code is gone" on a tree where it is still there — a vacuous
# pass, which is worse than no check at all.
file_not_contains_ml() {
    [ -f "$2" ] || return 1
    VERIFY_RE="$1" perl -0777 -ne 'exit($_ =~ /$ENV{VERIFY_RE}/s ? 1 : 0)' "$2"
}

# --- Fix A: every workflow module exposes a factory-rebuilt resetState --------
# Positive: an `initialState` factory exists, `state` is bound to it, and
# resetState rebuilds from it. Field-by-field resetState bodies are rejected on
# purpose (plan §4.1): they are the drift hazard this fix removes.

check_module_initialstate_factory() {
    local m=$1
    file_contains 'const initialState = \(\) =>' "store/$m.js" &&
    file_contains 'export const state = initialState' "store/$m.js"
}

check_module_resetstate_rebuilds() {
    local m=$1
    # The assertion is "the reset REBUILDS FROM THE FACTORY", not "Object.assign is the first
    # statement". The original pattern demanded `{` immediately followed by Object.assign, which went
    # red the moment store/picking.js gained a legitimate `clearInterval` guard ahead of it (review
    # finding M1) — a stale row reporting correct code as broken.
    #
    # But the obvious loosening to `.*?` under /s lost CONTAINMENT: the gap can span past the end of
    # the mutation, so a hand-listed resetState plus ANY later `Object.assign(state, initialState())`
    # elsewhere in the file (e.g. a `resetAll` helper) reported PASS — a false green, demonstrated in
    # review. The tempered-greedy `(?:(?!\n  \},).)*?` allows preceding statements while refusing to
    # cross the mutation's closing `\n  },`. Validated both ways: matches all 11 real modules
    # (including picking with the clearInterval guard in front), rejects the hand-listed PoC.
    file_contains_ml 'resetState\s*\(\s*state\s*\)\s*\{(?:(?!\n  \},).)*?Object\.assign\(\s*state\s*,\s*initialState\(\)\s*\)' \
        "store/$m.js"
}

# picking's reset owns a live setInterval handle; it must release it before dropping the handle, and
# must only ever clear one it created in THIS page load. Clearing a REHYDRATED id is not harmless —
# plugins/keycloak.client.js creates the token-refresh interval at boot and holds a low id, so
# clearInterval(state.timer) after a reload can silently stop token refresh (review finding M1).
check_picking_releases_interval() {
    # Two conjuncts, because the first alone stays green on DEAD CODE: if `setTimer` stopped writing
    # `liveTimer`, the matched `clearInterval(liveTimer)` could never fire and the row would still
    # pass (shown in review). Require the ownership assignment too.
    file_contains_ml 'resetState\s*\(\s*state\s*\)\s*\{(?:(?!\n  \},).)*?clearInterval\(\s*liveTimer\s*\)' store/picking.js &&
    file_contains_ml 'setTimer\s*\(\s*state\s*,\s*payload\s*\)\s*\{(?:(?!\n  \},).)*?liveTimer\s*=\s*payload' store/picking.js
}

check_picking_never_clears_rehydrated_handle() {
    file_not_contains 'clearInterval\(\s*state\.timer\s*\)' store/picking.js
}

# --- Fix B: the reset is committed from created(), inside the created block ---

check_page_created_resets() {
    local page=$1 module=$2
    file_contains_ml "created\\s*\\(\\s*\\)\\s*\\{[^}]*'${module}/resetState'" "pages/$page.vue"
}

# The page must no longer reset from mounted(). Block-scoped and multi-line: the
# construct being removed spans several lines inside the mounted() body, so a
# line-based grep would report it gone while it is still there.
check_page_no_mounted_setprocess() {
    local page=$1 module=$2
    file_not_contains_ml "mounted\\s*\\(\\s*\\)\\s*\\{[^}]*'${module}/setProcess'" "pages/$page.vue"
}

# --- Guards: things this fix must NOT change ---------------------------------

check_persistedstate_reducer_intact() {
    file_contains "key: 'vuex-mobile'" plugins/persistedState.client.js &&
    file_contains 'reducer:.*warehouseTimezone, selectedWarehouse, warehouses' \
        plugins/persistedState.client.js
}

check_no_root_state_reset() {
    # No resetState may be added to the root store — it holds warehouse/tenant
    # state that SBDEV-2726 and the UTC migration depend on (plan §0, §8.3).
    file_not_contains 'resetState' store/index.js
}

check_replenish_still_fetches() {
    # The one non-reset side effect that the mounted()->created() move could
    # silently drop (plan §4.2, R2).
    file_contains 'fetchHeldUp\(\)' pages/replenish.vue
}

check_putaway_control_intact() {
    file_contains_ml "created\\s*\\(\\s*\\)\\s*\\{[^}]*'putaway/resetState'" pages/putaway.vue
}

# --- Tests -------------------------------------------------------------------

check_spec_exists()  { [ -f "$1" ]; }

check_store_spec_pins_factory() {
    # The drift-proofing assertion must actually be deep-equality against the
    # module's own factory, not a hand-written literal (plan §8.1).
    file_contains 'toEqual\(' test/store/resetState.spec.js &&
    file_contains 'initialState|state\(\)' test/store/resetState.spec.js
}

check_page_spec_asserts_rendered_component() {
    # The ONLY assertion that separates a created() fix from a mounted()
    # half-fix (plan §2.4 probe 2). A spec that only checks state.process
    # false-greens on every partial page.
    file_contains 'findComponent' test/pages/workflow-reset-on-entry.spec.js
}

check_page_spec_covers_all_pages() {
    local f=test/pages/workflow-reset-on-entry.spec.js
    [ -f "$f" ] || return 1
    local p
    for p in cancellation cycle-count move-stock move-unitload transfer-order \
             palletizing picking replenish replenish-request truck-loading \
             lookup putaway; do
        grep -qE "pages/$p\.vue" "$f" || return 1
    done
}

jest_suite_passes() {
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    # shellcheck disable=SC1091
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1
    [ -x node_modules/.bin/jest ] || return 1
    node_modules/.bin/jest 2>&1 | grep -qE "Tests:.*[0-9]+ passed" &&
    ! (node_modules/.bin/jest 2>&1 | grep -qE "Tests:.*[0-9]+ failed")
}

# === Runner ==================================================================

echo
echo "verify-SBDEV-2930 — workflow pages must not resume the previous operator's state"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

echo "-- Fix A: resetState on every workflow module (plan §4.1) --"
for m in cancellation cycleCount lookup moveStock moveUnitload palletizing \
         picking putaway replenish transferOrder truckLoading; do
    run "A-$m"     "$m — initialState factory + state bound to it" \
        check_module_initialstate_factory "$m"
    run "A-$m-rb"  "$m — resetState rebuilds from initialState()" \
        check_module_resetstate_rebuilds "$m"
done

echo
echo "-- Review finding M1: picking's reset must release the interval it owns --"
run "M1-release"         "picking resetState clears the interval it created (liveTimer)"     check_picking_releases_interval
run "M1-no-rehydrated"   "picking never clearInterval()s a REHYDRATED state.timer id"        check_picking_never_clears_rehydrated_handle

echo
echo "-- Fix B: created() reset on all 11 changed pages (plan §4.2) --"
run "B-cancellation"     "cancellation.vue — created() commits cancellation/resetState"     check_page_created_resets cancellation cancellation
run "B-cycle-count"      "cycle-count.vue — created() commits cycleCount/resetState"        check_page_created_resets cycle-count cycleCount
run "B-move-stock"       "move-stock.vue — created() commits moveStock/resetState"          check_page_created_resets move-stock moveStock
run "B-move-unitload"    "move-unitload.vue — created() commits moveUnitload/resetState"    check_page_created_resets move-unitload moveUnitload
run "B-transfer-order"   "transfer-order.vue — created() commits transferOrder/resetState"  check_page_created_resets transfer-order transferOrder
run "B-palletizing"      "palletizing.vue — created() commits palletizing/resetState"       check_page_created_resets palletizing palletizing
run "B-picking"          "picking.vue — created() commits picking/resetState"               check_page_created_resets picking picking
run "B-replenish"        "replenish.vue — created() commits replenish/resetState"           check_page_created_resets replenish replenish
run "B-replenish-req"    "replenish-request.vue — created() commits replenish/resetState"   check_page_created_resets replenish-request replenish
run "B-truck-loading"    "truck-loading.vue — created() commits truckLoading/resetState"    check_page_created_resets truck-loading truckLoading
run "B-lookup"           "lookup.vue — created() commits lookup/resetState"                 check_page_created_resets lookup lookup

echo
echo "-- Fix B negative: the old partial mounted() resets are gone (plan §2.2) --"
run "BNEG-picking"       "picking.vue — no picking/setProcess in mounted()"                 check_page_no_mounted_setprocess picking picking
run "BNEG-replenish"     "replenish.vue — no replenish/setProcess in mounted()"             check_page_no_mounted_setprocess replenish replenish
run "BNEG-truck-loading" "truck-loading.vue — no truckLoading/setProcess in mounted()"      check_page_no_mounted_setprocess truck-loading truckLoading
run "BNEG-lookup"        "lookup.vue — no lookup/setProcess in mounted()"                   check_page_no_mounted_setprocess lookup lookup

echo
echo "-- Control + guards: what must NOT change (plan §7 row 7, §8.3, R2) --"
run "CTL-putaway"        "putaway.vue — created() reset still intact (control group)"        check_putaway_control_intact
run "GUARD-reducer"      "persistedState — vuex-mobile key + 3-key exclusion intact"        check_persistedstate_reducer_intact
run "GUARD-root"         "store/index.js — no resetState added to root state"               check_no_root_state_reset
run "GUARD-replenfetch"  "replenish.vue — fetchHeldUp() survived the refactor"              check_replenish_still_fetches

echo
echo "-- Tests (plan §8) --"
run "T-store-spec"       "test/store/resetState.spec.js exists"                             check_spec_exists test/store/resetState.spec.js
run "T-store-factory"    "store spec pins resetState to the state() factory"                check_store_spec_pins_factory
run "T-page-spec"        "test/pages/workflow-reset-on-entry.spec.js exists"                 check_spec_exists test/pages/workflow-reset-on-entry.spec.js
run "T-page-rendered"    "page spec asserts on findComponent, not just state.process"       check_page_spec_asserts_rendered_component
run "T-page-coverage"    "page spec references all 12 pages (11 fixed + putaway control)"   check_page_spec_covers_all_pages
run "T-jest"             "full Jest suite passes"                                           jest_suite_passes

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
