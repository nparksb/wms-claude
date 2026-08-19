#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-SBDEV-2947-sku-putaway-picker-storage-tier-default.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2947-sku-putaway-picker-storage-tier-default.md
#
#   WEB_UI_ROOT=/home/nampark/dev/wms-claude/v2/wms2-web-ui \
#     bash sbdocs/9-System/scripts/verify-SBDEV-2947-sku-putaway-picker-storage-tier-default.sh
#
# ONE root: this plan touches only v2/wms2-web-ui. When verifying implementation work, point
# WEB_UI_ROOT at the per-ticket worktree (or a symlink shadow root) or the script grades the main
# checkout instead of the work.
#
# ---------------------------------------------------------------------------
# BASELINE LABEL
# ---------------------------------------------------------------------------
#   Measured: 12 pass, 22 fail, 0 skip   <-- PRE-FIX baseline, 2026-08-13, r3 (34 rows), MEASURED
#   Against : v2/wms2-web-ui @ origin/develop 39eedd4 (a detached worktree, NOT the local checkout,
#             which was 19 commits behind and lacks editSkuPutawayDialog.vue entirely)
#
#   The 12 pre-fix passes are ALL preservation assertions about code that already exists.
#   If that count rises without implementation behind it, a check has gone vacuous — audit it.
#
# ⚠ ALWAYS SAY WHICH ROOT AND WHICH COMMIT A `Result:` LINE CAME FROM.
#
# ---------------------------------------------------------------------------
# EMPIRICAL AUDIT — run in BOTH directions at every revision, never eyeballed
# ---------------------------------------------------------------------------
#   * PRE-FIX  origin/develop 39eedd4 ............ 12 pass, 24 fail   (r3 final, 36 rows)
#   * TDD-GATE state (tests written, no fix) ..... 24 pass, 12 fail
#   * IMPLEMENTED (the shipped branch) ........... 36 pass,  0 fail   (Jest 83/83)
#
#   M15 (added at code review): remove the picker's per-subject `:key` -> C-key red AND the Jest row
#   `reKeysThePickerPerSubject...` red. 16/16 mutations caught across r1-r3.
#
#   14 / 14 targeted mutations CAUGHT across three revisions, one property each:
#     r1 (scope-driven default, superseded)
#       M1 inverted advice branches · M2 prop declared but data() keeps `false` · M3 watcher deleted
#       M4 wrong scope bound · M5 instruction gated AND duplicated on one line · M6 default:true
#       M7 offeredItems rewritten · M8 caption gate inverted
#     r2 (data-driven ADVICE, after a critic review falsified the plan's "structural" claim)
#       M9 revert to scope-driven advice · M10 catch-all v-else on the advice chain
#     r3 (data-driven DEFAULT, after surveying the UAT fleet — only 1 of 4 tenants is affected)
#       M11 drop the empty-array guard      -> A-empty  red, and Jest T24 red
#       M12 revert to scope-driven default  -> A-neg-scope + B-prop red
#       M13 caption re-gated on scope       -> D-gate + D-neg-scope red
#       M14 watcher shuts an opened tier    -> A-oneway red
#
#   FOUR REAL DEFECTS FOUND BY RUNNING THIS SCRIPT / ITS TESTS, all of which had passed review:
#     (a) D-gate PASSED VACUOUSLY pre-fix (r1). Its `</div>`-tempered gap leaked past a pre-existing
#         `<span v-if="scope !== 'SKU'">at this level</span>` — `</span>` is not `</div>`.
#     (b) SELF-wired FAILED against a correctly-wired script. It parsed the description field with
#         '"[^"]*"', which breaks on a row containing an escaped quote.
#     (c) `file_contains_n_times` wraps `grep -c`, which counts matching LINES — a duplicate on the
#         SAME line was invisible. Added `occurrences_at_most`.
#     (d) ⚠⚠ THE PLAN'S OWN WATCHER WAS WRONG, and test T24 caught it against an otherwise-correct
#         implementation: `immediate: true` fires before the first page of a PAGINATED read, and an
#         empty array has no goods-in option either — so without a `rows.length > 0` guard the tier
#         opened on EVERY tenant, visibly only under a slow read. The plan's comment described that
#         hazard while its code did not guard it. This is the strongest argument in this file for
#         writing the tests before the production code.
#
# ⚠⚠ THE LOCAL CHECKOUT WAS 19 COMMITS STALE WHEN THIS SCRIPT WAS WRITTEN, and the staleness is
#    load-bearing: `components/masterData/material/skuData/editSkuPutawayDialog.vue` and PR #56's
#    caption exist ONLY on origin/develop. Row X-base below fails loudly on a stale root rather than
#    letting every other row report against a tree that predates the feature.
#
# ---------------------------------------------------------------------------
# TEMPLATE FAIL-OPEN BUG — FIXED HERE. READ BEFORE EDITING A HELPER.
# ---------------------------------------------------------------------------
# `sbdocs/9-System/templates/verify-plan-template.sh` ships helpers built on `grep` and
# `perl -0777 -ne`. BOTH EXIT 0 WHEN THEY CANNOT OPEN THE FILE, so every assertion about a file that
# is not there yet reports PASS. That is not hypothetical for this plan: on the stale local checkout
# `editSkuPutawayDialog.vue` does not exist at all.
#
# FIX APPLIED: every helper below opens with `[ -f "$N" ] || return 1`. A missing file is a FAIL,
# never a PASS — including for the NEGATIVE helpers, where "the construct is absent" would otherwise
# be true only because the file is absent. Do not add a helper without that guard.
#
# ---------------------------------------------------------------------------
# THE OTHER FOUR RECORDED FAILURE MODES, AND HOW THIS SCRIPT AVOIDS EACH
# ---------------------------------------------------------------------------
# 1. VACUOUS NEGATIVES. A negative that is already true on an untouched tree carries no information
#    and goes green before the work starts. Fix B's negatives are the live risk here: on
#    origin/develop the sentence "Prefer a goods-in location" sits in the alert unconditionally, so
#    "it is not in the SKU branch" is meaningless until the branch exists. Every negative in this
#    script is therefore CONJOINED with the positive it qualifies (see check_B_advice_split), so it
#    cannot pass without the implementation.
# 2. UNDEFINED / UNWIRED FUNCTIONS. `run` records bash's 127 as a plain FAIL, and an undefined
#    function inside an `if` GUARD deletes its rows silently. This script has no conditional guards
#    at all — every row runs unconditionally — and the SELF-TEST block at the bottom asserts that
#    every `check_*` function defined is also wired to a `run`, and vice versa.
# 3. UNBOUNDED `.*?` UNDER /s LOSES CONTAINMENT. A lazy gap can match a correct construct somewhere
#    ELSE in the file. The two multiline rows here use a TEMPERED gap (`[^<]*` / `(?:(?!<\/v-alert>).)*`)
#    so the match cannot escape the block being asserted about.
# 4. ROWS GO STALE WHEN A REFACTOR MOVES CODE BETWEEN FILES. Kept small deliberately: each row names
#    the file the plan names, and there are only two production files. If a reviewer moves the copy
#    into a `putawayWording.js`-style module (as SBDEV-2643 B1 did), rows B-*/D-* must move with it.
#
# ⚠ TWO REGEX FLAVOURS IN ONE FILE. `file_contains` / `file_not_contains` are ERE (grep -qE);
#    `multiline_contains` / `multiline_not_contains` are perl (PCRE, /s). Do not hand `(?i)`,
#    lookahead or non-greedy quantifiers to the ERE helpers — they match literally.
#
# NEGATIVE-TEST THIS SCRIPT BEFORE TRUSTING IT: replay origin/develop and watch these rows go red.
# A "N pass, 0 fail" means nothing until you have seen the pre-fix tree fail.
# ---------------------------------------------------------------------------

set -u

WEB_UI_ROOT="${WEB_UI_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-web-ui}"
[ -d "$WEB_UI_ROOT" ] || { echo "FATAL: WEB_UI_ROOT=$WEB_UI_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

# --- paths (absolute, so no cd is needed and a wrong root fails loudly) ------
UI="$WEB_UI_ROOT"

F_PICKER="$UI/components/common/LocationPicker.vue"
F_FIELD="$UI/components/admin/parametersAndConfiguration/defaultPutawayLocationField.vue"
F_DIALOG="$UI/components/masterData/material/skuData/editSkuPutawayDialog.vue"

J_PICKER="$UI/test/components/common/locationPicker.spec.js"
J_FIELD="$UI/test/components/admin/defaultPutawayLocationField.spec.js"
J_DIALOG="$UI/test/components/masterData/material/skuData/editSkuPutawayDialog.spec.js"

# --- runner -----------------------------------------------------------------

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

# --- assertion helpers (every one guards file existence — see the header) ----

file_exists() { [ -f "$1" ]; }

file_contains() {
    [ -f "$2" ] || return 1
    grep -qE "$1" "$2"
}

file_not_contains() {
    [ -f "$2" ] || return 1
    ! grep -qE "$1" "$2"
}

file_contains_n_times() {
    [ -f "$2" ] || return 1
    local count
    count=$(grep -cE "$1" "$2" 2>/dev/null || echo 0)
    [ "$count" -ge "$3" ]
}

# ⚠ COUNTS OCCURRENCES, NOT LINES — and that distinction is why this helper exists.
# `file_contains_n_times` wraps `grep -c`, which counts MATCHING LINES. Mutation M5 exploited it: a
# second, ungated copy of the caption instruction inserted on the SAME line as the gated one left the
# line count at 1, and D-neg-ungated went green against a tree carrying exactly the duplicate it
# exists to forbid. Caught only by running the mutation. Any "appears exactly once" assertion about
# template markup must use this helper — Vue templates put many constructs on one line.
occurrences_at_most() {
    [ -f "$2" ] || return 1
    local count
    count=$(grep -oE "$1" "$2" 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -le "$3" ] && [ "$count" -ge 1 ]
}

# PCRE, whole file slurped, /s active. Use a TEMPERED gap, never a bare `.*?`.
multiline_contains() {
    [ -f "$2" ] || return 1
    MLC_PAT="$1" perl -0777 -ne 'exit($_ =~ /$ENV{MLC_PAT}/s ? 0 : 1)' "$2"
}

multiline_not_contains() {
    [ -f "$2" ] || return 1
    MLC_PAT="$1" perl -0777 -ne 'exit($_ =~ /$ENV{MLC_PAT}/s ? 1 : 0)' "$2"
}

# === X — root sanity =========================================================
# Not decoration. If the root is the stale checkout, editSkuPutawayDialog.vue is absent and the
# picker/field rows would grade a tree that predates the feature this plan fixes.

check_X_base_is_current() {
    file_exists "$F_DIALOG" && file_contains 'scope="SKU"' "$F_DIALOG"
}

check_X_picker_present() { file_exists "$F_PICKER"; }
check_X_field_present()  { file_exists "$F_FIELD"; }

# PR #56's caption must already be there — Fix D EDITS it. If it is missing, the root predates #56
# and row D-* would be asserting about copy that was never written.
check_X_pr56_caption_present() {
    file_contains 'in goods-in areas' "$F_FIELD"
}

# === A — Fix A: the tier opens from the DATA, never from scope ===============

check_A_has_goods_in_computed() {
    multiline_contains \
      'hasGoodsInOption\s*\(\)\s*\{(?:(?!\n    \}).)*items\.some(?:(?!\n    \}).)*eligible === true(?:(?!\n    \}).)*tier === .DEFAULT.' \
      "$F_PICKER"
}

# ⚠ A WATCHER ON `items`, NOT A mounted() HOOK. The caller accumulates a PAGINATED read, so at mount
# `items` is empty — and an empty array has no goods-in option either. A mounted() implementation
# would open the tier on EVERY tenant under a slow read, silently.
check_A_opens_from_items_watcher() {
    multiline_contains \
      'items:\s*\{(?:(?!\n    \},).)*immediate:\s*true(?:(?!\n    \},).)*hasGoodsInOption(?:(?!\n    \},).)*showAdvanced\s*=\s*true' \
      "$F_PICKER"
}

# ⚠ THE EMPTY-ARRAY GUARD. `immediate: true` fires before the first page of a PAGINATED read arrives,
# and an empty array has no goods-in option either — so without a length check the tier opens on every
# tenant, visibly only under a slow read. Found by test T24 against an otherwise-correct build.
check_A_watcher_guards_empty_rows() {
    check_A_opens_from_items_watcher \
      && multiline_contains \
        'items:\s*\{(?:(?!\n    \},).)*\.length\s*>\s*0(?:(?!\n    \},).)*showAdvanced\s*=\s*true' \
        "$F_PICKER"
}

check_A_starts_closed() {
    multiline_contains 'data\(\)\s*\{\s*return\s*\{[^}]*showAdvanced:\s*false' "$F_PICKER"
}

# ⚠ ONE-WAY. A later page must never shut a tier the operator opened, or Q4's "still flippable"
# promise is hollow. Conjoined so it cannot pass pre-fix.
check_A_watcher_is_one_way() {
    check_A_opens_from_items_watcher \
      && multiline_not_contains 'items:\s*\{(?:(?!\n    \},).)*showAdvanced\s*=\s*false' "$F_PICKER"
}

# ⚠ THE SUPERSEDED SCOPE-DRIVEN DEFAULT MUST BE GONE. r1/r2 keyed the gate on `advancedByDefault`;
# the UAT fleet showed that changes behaviour on 3 tenants with no defect. A revert goes red here.
check_A_no_scope_driven_default() {
    file_not_contains 'advancedByDefault' "$F_PICKER" \
      && file_not_contains 'advanced-by-default' "$F_FIELD" \
      && file_not_contains 'advancedByDefault' "$F_FIELD"
}

check_A_tier_filter_unchanged() {
    file_contains "row\.tier === 'DEFAULT'" "$F_PICKER" \
      && file_contains "this\.showAdvanced && row\.tier === 'ADVANCED'" "$F_PICKER"
}

check_A_toggle_still_flippable() {
    file_contains 'onToggleAdvanced' "$F_PICKER" \
      && file_contains 'label="Show storage locations"' "$F_PICKER" \
      && multiline_contains 'onToggleAdvanced\s*\(\s*\w+\s*\)\s*\{(?:(?!\n    \}).)*showAdvanced\s*=' "$F_PICKER"
}

# === B — Fix B: advice from the same single source of truth ==================

check_B_risk_paragraph_unconditional() {
    file_contains 'exclusive lock on the chosen' "$F_PICKER" \
      && file_contains 'database deadlock' "$F_PICKER"
}

check_B_advice_split() {
    multiline_contains \
      'v-if="hasGoodsInOption"(?:(?!</v-alert>).)*Prefer a goods-in location(?:(?!</v-alert>).)*v-else-if="dedicatedBinTier"(?:(?!</v-alert>).)*dedicated single-SKU bin' \
      "$F_PICKER"
}

check_B_goods_in_advice_not_unconditional() {
    check_B_advice_split \
      && multiline_not_contains 'v-if="advancedByDefault"' "$F_PICKER" \
      && multiline_not_contains 'v-if="dedicatedBinTier"(?:(?!</v-alert>).)*Prefer a goods-in location' "$F_PICKER"
}

check_B_advice_chain_is_total() {
    check_B_advice_split \
      && multiline_not_contains \
        'v-else-if="dedicatedBinTier"(?:(?!</v-alert>).)*dedicated single-SKU bin(?:(?!</v-alert>).)*<template v-else>' \
        "$F_PICKER"
}

check_B_prop_declared() {
    multiline_contains 'dedicatedBinTier:\s*\{[^}]*type:\s*Boolean[^}]*default:\s*false' "$F_PICKER"
}

# === C — Fix C: the wrapper passes the TIER, not a default ===================

check_C_binding_at_callsite() {
    multiline_contains '<location-picker(?:(?!/>).)*:dedicated-bin-tier="scope === .SKU."' "$F_FIELD"
}

# ⚠ THE SUBJECT BOUNDARY (code-review Medium). Without a subject-keyed picker the latched tier gate
# survives into the next SKU, and its caption then contradicts its own switch.
check_C_keyed_per_subject() {
    multiline_contains '<location-picker(?:(?!/>).)*:key="`\$\{scope\}-\$\{subjectId\}`"' "$F_FIELD"
}

# ⚠ THE SECOND HALF OF THE SUBJECT BOUNDARY, and the one the first fix attempt MISSED.
# `loadEligible()` is async and Vue 2 runs the subjectId user watcher before the render watcher, so a
# remounted picker reads the PREVIOUS subject's rows and latches the storage tier open on stale data.
# The key alone is not sufficient; ablation proves both halves are load-bearing.
check_C_clears_rows_on_subject_change() {
    multiline_contains \
      'resetForSubject\s*\(\)\s*\{(?:(?!\n    \},).)*this\.allRows = \[\](?:(?!\n    \},).)*this\.eligibleItems = \[\](?:(?!\n    \},).)*loadEligible\(\)' \
      "$F_FIELD"
}

# ⚠ THE REQUEST-GENERATION GUARD (third path to the same symptom, found at code review).
# The BUMP must sit BEFORE the SKU-needs-a-subject early return, so closing the dialog invalidates an
# in-flight read even though it dispatches none of its own. Asserted positionally for that reason:
# moving the bump below the return leaves every behavioural test green except the close-path one.
check_C_generation_guard() {
    multiline_contains \
      'const generation = \+\+this\.loadGeneration(?:(?!\n    \},).)*if \(this\.scope === .SKU. && this\.subjectId == null\)(?:(?!\n    \},).)*if \(generation !== this\.loadGeneration\) return' \
      "$F_FIELD" \
      && file_contains 'loadGeneration: 0' "$F_FIELD"
}

# A superseded read must not clear the spinner while the current one is still in flight.
# ⚠ The close path must clear the spinner ITSELF. The generation guard makes the superseded read's
# `finally` refuse to, and this return issues no read of its own — so without this `loading` latches
# true for as long as the subject is null and nothing can clear it.
check_C_close_path_clears_spinner() {
    multiline_contains \
      'if \(this\.scope === .SKU. && this\.subjectId == null\) \{(?:(?!\n      \}).)*this\.loading = false(?:(?!\n      \}).)*return' \
      "$F_FIELD"
}

# A successful read returning ZERO rows must still say something rather than render nothing at all.
#
# ⚠ POSITIVE ONLY, ON PURPOSE. This row briefly also asserted that the phrase "0 of 0 locations can be
# used" appears nowhere in the file — a row that COULD NEVER PASS: that phrasing lives in a
# pre-existing SBDEV-2732 comment explaining why M4 removed it, and in this change's own rationale.
# Making the row green would have meant rewording unrelated historical prose. The positive below is
# the actual requirement; the M4 claim is prevented structurally, because this branch renders an
# availability statement instead of a count and the count branch cannot be reached with zero rows.
check_D_empty_set_is_stated() {
    multiline_contains \
      'v-else-if="!loadIncomplete && allRows\.length === 0"(?:(?!</div>).)*No locations are available' "$F_FIELD"
}

check_C_generation_guards_finally() {
    multiline_contains \
      'finally\s*\{(?:(?!\n    \},).)*generation === this\.loadGeneration(?:(?!\n    \},).)*this\.loading = false' \
      "$F_FIELD"
}

# ⚠ THE PREVIEW RACE — sibling of the eligible-locations guard, and the damaging one: `blockingReason`
# gates Save, so a stale verdict BLOCKS a legal configuration rather than merely misleading.
check_C_preview_generation_guard() {
    multiline_contains \
      'const generation = \+\+this\.previewGeneration(?:(?!\n    \},).)*if \(this\.selectedId == null\)(?:(?!\n    \},).)*if \(generation !== this\.previewGeneration\) return' \
      "$F_FIELD" \
      && file_contains 'previewGeneration: 0' "$F_FIELD"
}

# ⚠ Clearing the selection must route THROUGH refreshPreview() so it bumps the generation. An early
# return in onSelect leaves an in-flight preview live, and its verdict lands on a cleared field.
check_C_clear_routes_through_preview() {
    multiline_contains \
      'async onSelect\s*\((?:(?!\n    \},).)*await this\.refreshPreview\(\)' "$F_FIELD" \
      && multiline_not_contains \
        'async onSelect\s*\((?:(?!\n    \},).)*if \(locationId == null\) return' "$F_FIELD"
}

# ⚠ EVERY preview DISCARD must invalidate an in-flight one, not just refreshPreview()'s own call.
# `resetForSubject()` and the `value` watcher discard the preview WITHOUT issuing one, so bumping only
# inside refreshPreview() left a subject change unguarded — SKU A's verdict landed on SKU B and
# disabled Save. Asserted on resetPreview() because that is the single chokepoint all discards share.
check_C_reset_preview_bumps() {
    multiline_contains \
      'resetPreview\s*\(\)\s*\{(?:(?!\n    \},).)*\+\+this\.previewGeneration' "$F_FIELD"
}

# ⚠ `loading` STARTS TRUE: mounted() awaits resolveSbAdmin() before the first read, so the initial
# render precedes any dispatch — and with it false the empty-set branch claimed "none available"
# before anyone had asked. Same class M4 removed.
check_C_loading_starts_true() {
    file_contains 'loading: true,' "$F_FIELD" \
      && file_not_contains 'loading: false,' "$F_FIELD"
}

check_C_single_callsite() {
    [ -d "$UI/components" ] || return 1
    local n
    n=$(grep -rlE '<location-picker' "$UI/components" 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" = "1" ]
}

# === D — Fix D: the caption instruction follows the SAME fact ================

check_D_split_still_unconditional() {
    file_contains 'in goods-in areas' "$F_FIELD" \
      && file_contains 'eligibleAdvancedCount' "$F_FIELD" \
      && file_contains 'eligibleDefaultCount' "$F_FIELD"
}

# ⚠ GATED ON `eligibleDefaultCount > 0`, NOT ON SCOPE. r2 used `scope !== 'SKU'`, which strands a
# hydra operator at SKU scope: there the tier does NOT auto-open, so the instruction is still needed.
check_D_instruction_gated_on_goods_in() {
    multiline_contains 'v-if="eligibleDefaultCount > 0">[^<]*Enable[^<]*Show storage locations' "$F_FIELD"
}

check_D_no_scope_gate_on_instruction() {
    check_D_instruction_gated_on_goods_in \
      && multiline_not_contains 'v-if="scope !== .SKU.">[^<]*Enable' "$F_FIELD" \
      && occurrences_at_most 'Enable &ldquo;Show storage locations&rdquo;' "$F_FIELD" 1
}

# === J — Jest coverage (§6). Shape rows; the suite run is the behaviour gate ==

check_J_picker_opens_on_empty_row() {
    file_contains 'T18' "$J_PICKER" && multiline_contains 'showAdvanced\)\.toBe\(true\)' "$J_PICKER"
}

# The regression guard for the 3 UNAFFECTED tenants: a goods-in option must leave the tier closed.
check_J_picker_stays_closed_row() {
    file_contains 'T19' "$J_PICKER" && multiline_contains 'showAdvanced\)\.toBe\(false\)' "$J_PICKER"
}

check_J_picker_advice_both_ways() {
    file_contains 'dedicated single-SKU bin' "$J_PICKER" \
      && file_contains 'Prefer a goods-in location' "$J_PICKER" \
      && multiline_contains '\.not\.(?:toContain|toMatch)\((?:(?!\)).)*Prefer a goods-in location' "$J_PICKER" \
      && multiline_contains '\.not\.(?:toContain|toMatch)\((?:(?!\)).)*dedicated single-SKU bin' "$J_PICKER"
}

# T21b = tier 1 WITH goods-in options (hydra/shipitez). T22b = tier 2/3 with none (say nothing).
check_J_picker_advice_is_data_driven() {
    file_contains 'T21b' "$J_PICKER" && file_contains 'T22b' "$J_PICKER"
}

# ⚠ T24/T24b PIN THE ASYNC CONTRACT — the paginated-accumulate trap that forbids a mounted() hook,
# and the one-way rule. Without these a mounted() implementation passes every other row.
check_J_picker_async_rows() {
    file_contains 'T24' "$J_PICKER" \
      && file_contains 'T24b' "$J_PICKER" \
      && multiline_contains 'setProps\(\{\s*items' "$J_PICKER"
}

check_J_picker_flippable_row() {
    multiline_contains "change'?,\s*false\)|change',\s*false" "$J_PICKER"
}

check_J_field_prop_both_ends() {
    file_contains "props\('dedicatedBinTier'\)" "$J_FIELD" \
      && file_contains "'MERCHANT'" "$J_FIELD" \
      && multiline_contains "props\('dedicatedBinTier'\)\)\.toBe\(true\)" "$J_FIELD" \
      && multiline_contains "props\('dedicatedBinTier'\)\)\.toBe\(false\)" "$J_FIELD"
}

# The wrapper must not become a second authority on the default.
# ⚠ REQUIRES THE BEHAVIOURAL ROW, not merely the key-shaped one. The first version of this check
# grepped only for the key test's name — and that test asserted `$vnode.key` under shallowMount, where
# the picker is a STUB and `showAdvanced` is unobservable. It was green on a branch where the property
# was false. Both mechanism rows are cheap companions; the behavioural row is the actual contract.
check_J_field_subject_key_row() {
    file_contains 'doesNotCarryTheAutoOpenedTierIntoASubjectThatHasGoodsInOptions' "$J_FIELD" \
      && file_contains 'clearsTheCandidateRowsOnSubjectChangeSoNoLatchOnStaleData' "$J_FIELD" \
      && file_contains 'reKeysThePickerPerSubjectSoTheTierGateCannotLatchAcross' "$J_FIELD" \
      && multiline_contains 'doesNotCarryTheAutoOpenedTier(?:(?!\n  \}\)).)*mount\(DefaultPutawayLocationField' "$J_FIELD" \
      && multiline_contains 'doesNotCarryTheAutoOpenedTier(?:(?!\n  \}\)).)*showAdvanced\)\.toBe\(false\)' "$J_FIELD"
}

# Both race rows: the out-of-order response AND the close-path invalidation. The second is the one a
# mutation escaped without — moving the bump below the early return passes everything else.
check_J_field_race_rows() {
    file_contains 'dropsALateResponseFromASupersededSubject' "$J_FIELD" \
      && file_contains 'invalidatesAnInFlightReadWhenTheSubjectGoesAway' "$J_FIELD"
}

check_J_field_preview_race_rows() {
    file_contains 'dropsALatePreviewFromASupersededSelection' "$J_FIELD" \
      && file_contains 'invalidatesAnInFlightPreviewWhenTheSelectionIsCleared' "$J_FIELD" \
      && file_contains 'invalidatesAnInFlightPreviewWhenTheSubjectChanges' "$J_FIELD" \
      && file_contains 'makesNoAvailabilityClaimBeforeTheFirstReadIsIssued' "$J_FIELD"
}

check_J_field_no_default_flag_row() {
    file_contains 'negDoesNotPassAnOpenTheTierFlag' "$J_FIELD"
}

# BOTH caption cases: dropped when the tier auto-opens, KEPT when goods-in options exist at SKU scope.
check_J_field_caption_both_cases() {
    file_contains 'skuCaptionDropsTheInstructionWhenTheTierAutoOpens' "$J_FIELD" \
      && file_contains 'skuCaptionKEEPSTheInstructionWhenGoodsInOptionsExist' "$J_FIELD"
}

check_J_field_pr56_rows_survive() {
    file_contains '0 in goods-in areas \(none\)' "$J_FIELD" && file_contains '1 in goods-in areas' "$J_FIELD"
}

check_J_dialog_mounted_row() {
    file_contains 'mount\(' "$J_DIALOG" && ! file_contains_n_times 'shallowMount' "$J_DIALOG" 99
}

# === Wire into the runner ====================================================

echo
echo "verify-SBDEV-2947 — Default Putaway Location picker: storage tier at SKU scope"
echo "  WEB_UI_ROOT=$WEB_UI_ROOT"
if command -v git >/dev/null 2>&1 && git -C "$WEB_UI_ROOT" rev-parse --short HEAD >/dev/null 2>&1; then
    echo "  HEAD=$(git -C "$WEB_UI_ROOT" rev-parse --short HEAD) ($(git -C "$WEB_UI_ROOT" rev-parse --abbrev-ref HEAD))"
fi
echo

echo "  -- X: root sanity (a stale root invalidates every row below) --"
run X-base         "root carries SBDEV-2643 B2's SKU dialog"            check_X_base_is_current
run X-picker       "LocationPicker.vue present"                          check_X_picker_present
run X-field        "defaultPutawayLocationField.vue present"             check_X_field_present
run X-pr56         "root carries PR #56's tier-split caption"            check_X_pr56_caption_present
echo

echo "  -- A: Fix A — the tier opens from the DATA, not from scope --"
run A-computed     "A — hasGoodsInOption reads the server's tier"          check_A_has_goods_in_computed
run A-watcher      "A — opens via an items watcher (not mounted())"        check_A_opens_from_items_watcher
run A-empty        "A — watcher ignores the pre-first-page empty array" check_A_watcher_guards_empty_rows
run A-closed       "A — showAdvanced still STARTS closed"                  check_A_starts_closed
run A-oneway       "A — the watcher never shuts an opened tier"            check_A_watcher_is_one_way
run A-neg-scope    "A — superseded scope-driven default is gone"           check_A_no_scope_driven_default
run A-filter       "A — offeredItems tier predicate unchanged"             check_A_tier_filter_unchanged
run A-flip         "A — the switch is still user-flippable (Q4)"           check_A_toggle_still_flippable
echo

echo "  -- B: Fix B — advice from the same single source of truth --"
run B-risk         "B — deadlock risk paragraph stays unconditional"       check_B_risk_paragraph_unconditional
run B-prop         "B — dedicatedBinTier declared, Boolean, default false" check_B_prop_declared
run B-advice       "B — goods-in first, dedicated-bin fallback"            check_B_advice_split
run B-neg-advice   "B — goods-in advice unreachable with no goods-in row"  check_B_goods_in_advice_not_unconditional
run B-total        "B — no catch-all v-else printing tier-1 wording"       check_B_advice_chain_is_total
echo

echo "  -- C: Fix C — the wrapper passes the tier, not a default --"
run C-bind         "C — dedicated-bin-tier bound from scope"               check_C_binding_at_callsite
run C-key          "C — picker re-keyed per subject (tier gate cannot latch)" check_C_keyed_per_subject
run C-clear        "C — resetForSubject clears rows before the async reload" check_C_clears_rows_on_subject_change
run C-gen          "C — generation guard, bumped BEFORE the early return"    check_C_generation_guard
run C-gen-fin      "C — a superseded read cannot clear the spinner"          check_C_generation_guards_finally
run C-gen-close    "C — the close path clears the spinner itself"            check_C_close_path_clears_spinner
run C-prev-gen     "C — refreshPreview generation-guarded (gates Save)"      check_C_preview_generation_guard
run C-prev-clear   "C — clearing routes through refreshPreview to invalidate" check_C_clear_routes_through_preview
run C-prev-reset   "C — every preview discard invalidates (resetPreview bumps)" check_C_reset_preview_bumps
run C-load-true    "C — loading starts true: no claim before the first read"  check_C_loading_starts_true
run D-empty        "D — an empty candidate set is stated, not silence"       check_D_empty_set_is_stated
run C-single       "C — exactly one <location-picker> in components/"      check_C_single_callsite
echo

echo "  -- D: Fix D — caption instruction follows the same fact --"
run D-split        "D — tier split stated at every scope"                  check_D_split_still_unconditional
run D-gate         "D — Enable-instruction gated on eligibleDefaultCount"  check_D_instruction_gated_on_goods_in
run D-neg-scope    "D — superseded scope gate on the instruction is gone"  check_D_no_scope_gate_on_instruction
echo

echo "  -- J: Jest coverage (shape only — the suite run is the behaviour gate) --"
run J-pick-open    "J — row asserts the tier OPENS on an empty goods-in tier" check_J_picker_opens_on_empty_row
run J-pick-closed  "J — row pins it STAYS CLOSED when goods-in exists"        check_J_picker_stays_closed_row
run J-pick-advice  "J — advice asserted both ways, with .not. on each"        check_J_picker_advice_both_ways
run J-pick-data    "J — T21b/T22b pin the DATA-driven advice rule"            check_J_picker_advice_is_data_driven
run J-pick-async   "J — T24/T24b pin the async + one-way contract"            check_J_picker_async_rows
run J-pick-flip    "J — row covers switching the tier back off"               check_J_picker_flippable_row
run J-field-prop   "J — dedicatedBinTier asserted true AND false"             check_J_field_prop_both_ends
run J-field-race   "J — rows cover out-of-order AND close-path invalidation"  check_J_field_race_rows
run J-field-prev   "J — rows cover the preview race, both directions"        check_J_field_preview_race_rows
run J-field-nodef  "J — wrapper passes no open-the-tier flag"                 check_J_field_no_default_flag_row
run J-field-key    "J — row pins the per-subject picker key"                  check_J_field_subject_key_row
run J-field-cap    "J — caption rows cover BOTH drop and keep"                check_J_field_caption_both_cases
run J-field-pr56   "J — PR #56's WAREHOUSE caption rows survive"              check_J_field_pr56_rows_survive
run J-dialog       "J — SKU dialog row uses a real mount()"                   check_J_dialog_mounted_row
echo

# === SELF-TEST — failure mode 2: a defined-but-unwired check is dead code =====
# `run` records bash's 127 for an undefined function as an ordinary FAIL, indistinguishable from
# unfinished work; and a check defined but never wired simply never runs. Both are caught here.

echo "  -- self-test --"
check_self_all_checks_wired() {
    local self="${BASH_SOURCE[0]}"
    [ -f "$self" ] || return 1
    local defined wired
    # ⚠ DO NOT try to parse the description field out of a `run` line. The first version matched
    # '^run [^ ]+ +"[^"]*" +check_...' and broke on the one row whose description contains an ESCAPED
    # quote (C-bind: "…:advanced-by-default=\"scope === 'SKU'\""), so `wired` came back short and this
    # self-test failed against a correctly-wired script. Match the token anywhere on a `run` line.
    defined=$(grep -oE '^check_[a-zA-Z0-9_]+\(\)' "$self" | tr -d '()' | grep -v '^check_self' | sort -u)
    wired=$(grep -E '^run ' "$self" | grep -oE 'check_[a-zA-Z0-9_]+' | grep -v '^check_self' | sort -u)
    # Every defined check is wired, and every wired check is defined. Conjoined helper calls
    # (check_B_advice_split inside check_B_goods_in_advice_not_unconditional) are themselves wired,
    # so a plain set comparison is correct here.
    [ "$defined" = "$wired" ]
}
run SELF-wired     "every check_* is defined AND wired to a run row"     check_self_all_checks_wired

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
