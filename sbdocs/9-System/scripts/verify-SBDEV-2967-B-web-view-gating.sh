#!/usr/bin/env bash
# verify-SBDEV-2967-B-web-view-gating.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2967-B-web-view-gating.md
#
# Usage:
#   PROJECT_ROOT=/path/to/owl bash sbdocs/9-System/scripts/verify-SBDEV-2967-B-...sh
#
# PROJECT_ROOT is MONO-ROOTED — it must contain v2/wms2-web-ui and v2/wms2-api.
# Against a per-ticket worktree, point it at a symlink shadow root or it grades the
# main checkout. (37 of 44 verify scripts want the SUB-REPO root; this one does not.
#  Passing the wrong shape reds every row as credible, honest-looking work-not-done.)
#
# Run BEFORE any change for the FAIL baseline. Acceptance is "Result: N pass, 0 fail".
#
# Carved out of verify-SBDEV-2967-web-ui-function-gating-enforcement.sh on 2026-08-21.
# ACTION-gate rows are NOT here — they are in verify-SBDEV-2967-C-web-action-gating.sh,
# and they were rewritten, because the pre-split rows E1-E9 encoded the service-layer
# placement that the plan's own architect review had already reversed.
#
# Helpers are hardened: the stock template's file_not_contains is `! grep ...`, which
# returns TRUE for a file that does not exist, false-greening every negative assertion
# about a NEW file. Each helper below requires the file to exist first.
set -uo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
WEB="$PROJECT_ROOT/v2/wms2-web-ui"
API="$PROJECT_ROOT/v2/wms2-api"
SRC="$API/src/main/java/net/aim_ai/wms"
TST="$API/src/test/java/net/aim_ai/wms"

# ⚠️ EXPORTED ON PURPOSE — 2026-08-21, and this is load-bearing.
# Rows below use `bash -c '...'` with SINGLE quotes so that regex backslashes survive unmangled.
# Single quotes mean the OUTER shell does not expand $WEB/$MIG/... — the child shell must inherit
# them. Without these exports every such row is broken in one of two silent ways:
#   · a `perl -0777 -ne` row reads EMPTY STDIN instead of a file, and perl exits 0 -> PASS, asserting
#     nothing (this is the fail-open trap already recorded against the plan template's helpers);
#   · a row guarded by `[ -f "$X" ]` sees `[ -f "" ]` -> FAIL forever, reading as honest work-not-done.
# Both were live in this script on 2026-08-21 and were caught only by negative-testing a fake
# migration. Every perl row below ALSO carries its own `[ -f ... ] || exit 1` for the same reason.
# All row paths live here, exported, ABOVE every row. Defining one next to the row that uses it is
# how B8 came to reference $AML 200 lines before its assignment: empty var -> `[ -f "" ]` -> a
# permanent FAIL that reads as honest work-not-done. One block, one place to look.
LAYOUT="$WEB/layouts/default.vue"
MENUFILE="$WEB/util/appMenuList.js"
AML="$WEB/util/appMenuList.js"
MW="$WEB/middleware/require-function.js"
PS="$WEB/plugins/persistedState.client.js"
STOREIDX="$WEB/store/index.js"
ADMINPAGE="$WEB/pages/admin.vue"
INDEXPAGE="$WEB/pages/index.vue"
export WEB API SRC TST UT LAYOUT MENUFILE AML MW PS STOREIDX ADMINPAGE INDEXPAGE
PASS=0; FAIL=0; SKIP=0
run() { local id=$1 d=$2; shift 2
  if "$@" >/dev/null 2>&1; then printf "  PASS  %-9s %s\n" "$id" "$d"; PASS=$((PASS+1))
  else printf "  FAIL  %-9s %s\n" "$id" "$d"; FAIL=$((FAIL+1)); fi; }
skip() { printf "  SKIP  %-9s %s\n" "$1" "$2"; SKIP=$((SKIP+1)); }

# ⚠️ STRIP COMMENTS BEFORE ANY NEGATIVE ASSERTION. Added 2026-08-21 (3rd pass) after FOUR rows
# (A2, A3, F6, H13b) failed a CORRECT implementation because the code's own comments quoted the very
# literal the row forbids — "Was `menuList[\"super-admin\"]`" and "NEVER ON CONFLICT" are exactly the
# kind of comment a good fix carries. A negative grep over raw source therefore punishes documenting
# the decision. This is a recorded landmine class in this repo; do not add a `! grep` without it.
#   $1 = file, $2 = comment style (js | sql)
strip_comments() {
  case "$2" in
    sql) sed -e 's/--.*$//' "$1" ;;
    *)   sed -e 's://.*$::' "$1" | perl -0777 -pe 's{/\*.*?\*/}{}gs' ;;
  esac
}
export -f strip_comments 2>/dev/null || true

file_exists()      { [ -f "$1" ]; }
dir_exists()       { [ -d "$1" ]; }
file_contains()    { [ -f "$2" ] || return 1; grep -qE "$1" "$2"; }
file_not_contains(){ [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }
file_contains_n()  { [ -f "$2" ] || return 1; local c; c=$(grep -cE "$1" "$2" 2>/dev/null || echo 0); [ "$c" -ge "$3" ]; }
tree_contains()    { [ -d "$2" ] || return 1; grep -rqE "$1" "$2"; }

MENU="$WEB/util/appMenuList.js"
STORE="$WEB/store/index.js"
ADMIN="$WEB/pages/admin.vue"
UT="$SRC/controller/rest/UtilRestController.java"

echo; echo "SBDEV-2967-B — web UI view gating (menu, routes, entry, admin tabs)"; echo "PROJECT_ROOT=$PROJECT_ROOT"; echo

# A stale checkout reds rows that are genuinely green on develop, and the output is
# indistinguishable from unimplemented work. Say which it is, up front.
if git -C "$API" rev-parse --verify origin/develop >/dev/null 2>&1; then
  behind=$(git -C "$API" rev-list --count HEAD..origin/develop 2>/dev/null || echo 0)
  if [ "${behind:-0}" -gt 0 ]; then
    echo "  ⚠ $API is $behind commit(s) behind origin/develop."
    echo "    Rows that assert SBDEV-2968's landed surface will red for that reason alone."
    echo "    Fetch/rebase, or point PROJECT_ROOT at a current shadow root, before judging."
    echo
  fi
fi

# --------------------------------------------------------------------------
echo "Fix A — the menu filter"
# --------------------------------------------------------------------------
run A1 "appMenuList.js exists"                                   file_exists "$MENU"
# THE headline defect: the menu must no longer be hardcoded to the super-admin key.
run A2 "links() no longer hardcodes menuList[\"super-admin\"]" bash -c '
    [ -f "$LAYOUT" ] || exit 1
    # comment-stripped: a fix that DOCUMENTS what it replaced must not fail this row
    ! strip_comments "$LAYOUT" js | grep -qE "menuList\\[.super-admin.\\]"' 
# FIXED 2026-08-21 (3rd pass): the old single-line regex `functions.*\.filter\(` FAILED A CORRECT
# implementation -- a real `links()` reads `this.$store.state.functions` into a local on one line and
# filters on a later one, and any recursive prune (required by B-23 for the Master Data sub-groups)
# puts them in different functions entirely. MEASURED FAIL against a working reference. The behaviour
# is owned by default.spec (5 tests incl. csRep + depth-2); this row only asserts the hardcoded
# super-admin read is GONE, which is the one thing a grep can settle here.
run A3 "  ... and reads state.functions instead (behaviour: default.spec)" bash -c '
    [ -f "$LAYOUT" ] || exit 1
    strip_comments "$LAYOUT" js | grep -qE "state\\.functions"' 
run A4 "the 4 dead persona menus are gone" bash -c "
    f='$MENU'; [ -f \"\$f\" ] || exit 1
    for k in 'inventory-manager' 'outbound-manager' 'receiving'; do
      grep -qE \"^\\s*[\\\"']?\$k[\\\"']?\\s*:\" \"\$f\" && exit 1
    done; exit 0"
run A5 "every menu leaf declares a fn" bash -c "
    f='$MENU'; [ -f \"\$f\" ] || exit 1
    leaves=\$(grep -cE '^\s*(to|href)\s*:' \"\$f\"); fns=\$(grep -cE '^\s*fn\s*:' \"\$f\")
    [ \"\$leaves\" -gt 0 ] && [ \"\$fns\" -ge \"\$leaves\" ]"
run A6 "menu references WEB_UI_ constants (not bare strings)"    file_contains 'WEB_UI_VIEW_' "$MENU"
run A7 "  ... and covers the ANY-of Handling Units leaf"         file_contains 'WEB_UI_VIEW_STOCK_UNIT' "$MENU"
run A8 "store commits the fetched functions"                     file_contains 'commit\(.set(Functions|UserFunctions)' "$STORE"
run A9 "store exposes ensureFunctionsLoaded"                     file_contains 'ensureFunctionsLoaded' "$STORE"
run A10 "  ... getUserRoles no longer discards its result"       file_not_contains "console\.log\('getUserRoles:', results\.length\)" "$STORE"

# --------------------------------------------------------------------------
echo; echo "Fix B — the route guard"
# --------------------------------------------------------------------------
run B1 "middleware/ directory exists"                            dir_exists "$WEB/middleware"
run B2 "require-function middleware exists"                      file_exists "$MW"
run B3 "  ... awaits ensureFunctionsLoaded before deciding"      file_contains 'await[^;]*ensureFunctionsLoaded' "$MW"
run B4 "  ... redirects to /not-authorized"                      file_contains 'not-authorized' "$MW"
run B5 "  ... handles the fetch-failure state separately"        file_contains 'unhealthy-tenant|functionsError' "$MW"
# ═══ B6 DELETED 2026-08-21 (2nd pass), deliberately and permanently. ═══
# This row tried three times to assert "an unclassified route is DENIED, not waved through":
#   v1  asserted the OPPOSITE policy ("unmapped routes fall through") -- correct for mobile, wrong here.
#   v2  greped for the noun UNGATED_ROUTES -- which mobile's fail-OPEN guard satisfies VERBATIM.
#   v3  forbade the syntactic shape `if (!required) return` -- MEASURED INVERTED: it passed a
#       mobile-style fail-open port and FAILED a correct fail-closed guard, because the real
#       difference is that one returns nothing and the other returns a redirect. That is semantics,
#       and no regex over source text can see it.
# The property is owned behaviourally, where it belongs:
#   · requireFunction.spec#deniesAnUnclassifiedRouteRatherThanWavingItThrough
#   · requireFunction.spec#deniesWhenFunctionsCannotBeLoaded
#   · verify H4 below, which pins the /unhealthy-tenant redirect TARGET near the functionsLoaded
#     branch -- measured RED against fail-open and PASS against fail-closed.
# A deleted row is strictly better than a row that reads as coverage and is not. Do not re-add it.

run B7 "middleware registered in nuxt.config.js"                 file_contains 'require-function' "$WEB/nuxt.config.js"
# P7: detail routes must be enumerated, not left to fall through.
# FIXED 2026-08-21 (3rd pass): B8 grepped the MIDDLEWARE for a detail-route pattern, but §2.2(a) puts
# EXTRA_ROUTES in util/appMenuList.js and has the middleware import requiredFunctionFor -- so this row
# FAILED a correct implementation, and `detail` also matched a mere comment. Point it at the file that
# actually owns the map (H6-H8 assert its contents); behaviour is owned by
# requireFunction.spec#detailRoutesInheritTheirListPageFunction + resolvesEveryExtraRoute...
run B8 "  ... the route map names the :id detail routes (in appMenuList, per §2.2a)" bash -c '
    [ -f "$AML" ] || exit 1
    perl -0777 -ne "exit 1 unless /EXTRA_ROUTES[^;]*?(:id|_id)/s" "$AML"'

# --------------------------------------------------------------------------
echo; echo "Fix C — the WEB_UI_LOG_IN entry gate"
# --------------------------------------------------------------------------
run C1 "WEB_UI_LOG_IN is checked somewhere on entry" bash -c "
    grep -rq 'WEB_UI_LOG_IN' '$WEB/pages' 2>/dev/null ||
    grep -q  'WEB_UI_LOG_IN' '$WEB/middleware/require-function.js' 2>/dev/null"

# --------------------------------------------------------------------------
echo; echo "Fix D — the 7 admin tabs (Label Printing added by SBDEV-2861)"
# --------------------------------------------------------------------------
run D1 "admin tabs carry functions"                              file_contains 'WEB_UI_VIEW_USER_MANAGEMENT' "$ADMIN"
run D2 "  ... System Management -> IMPORT_DATA"                  file_contains 'WEB_UI_VIEW_IMPORT_DATA' "$ADMIN"
run D3 "  ... Parameters -> SYSTEM_PROPERTY"                     file_contains 'WEB_UI_VIEW_SYSTEM_PROPERTY' "$ADMIN"
run D4 "  ... Printer Setup -> PRINTER"                          file_contains 'WEB_UI_VIEW_PRINTER' "$ADMIN"
run D5 "  ... Service Log -> MESSAGES"                           file_contains 'WEB_UI_VIEW_MESSAGES' "$ADMIN"
# Label Printing shares Printer Setup's gate by decision (Nam 2026-08-21) -- no
# WEB_UI_VIEW_LABEL_PRINTING constant exists and this slice already mints one new constant.
run D5b "  ... Label Printing -> PRINTER (shared gate)" bash -c "
    f='$WEB/pages/admin.vue'; [ -f \"\$f\" ] || exit 1
    perl -0777 -ne 'exit 1 unless /Label Printing.{0,200}WEB_UI_VIEW_PRINTER/s' \"\$f\""
run D6 "  ... Shippers -> CLIENT"                                file_contains 'WEB_UI_VIEW_CLIENT' "$ADMIN"
run D7 "  ... the tab list is filtered, not rendered whole"      file_contains '\.filter\(' "$ADMIN"

# --------------------------------------------------------------------------
echo; echo "Fix F(VIEW) — grant seed + migration"
# --------------------------------------------------------------------------
# ASSOCIATION, not presence. A bare `grep WEB_UI_VIEW_ITEM_DATA` pre-passes: every
# WEB_UI_VIEW_* constant is ALREADY in this file, granted to role_super_admin. The row
# must prove the constant reaches role_inventory_manager. `[^;]*` is a tempered gap --
# it cannot cross a statement terminator, so it cannot match a DIFFERENT grant nearby.
# FIXED 2026-08-21 (3rd pass): F1 required each constant to appear inside a `grantFunction(CONST, ...
# role_inventory_manager)` varargs call. A LOOP-shaped seed -- `for (String fn : MASTER_DATA)
# grantFunction(fn, role_inventory_manager)` -- is equally correct and arguably better than 12 more
# lines, and it MEASURED RED. The which-function-to-which-role property is a data question that a
# grep cannot answer once the constants move into an array; it is owned by
# UtilRestControllerSeedUnitTest#seedsMasterDataFunctionsToInventoryManager, which reconstructs the
# (function, role) pairs from the captured calls. This row now asserts only that the constants are
# NAMED in the seed at all -- with a trailing boundary so a longer sibling cannot satisfy one.
run F1 "seed NAMES the master-data constants (association: UtilRestControllerSeedUnitTest)" bash -c '
    [ -f "$UT" ] || exit 1
    for c in WEB_UI_VIEW_STORAGE_LOCATION WEB_UI_VIEW_ITEM_DATA WEB_UI_VIEW_SECTION WEB_UI_VIEW_AREA \
             WEB_UI_VIEW_CYCLECOUNT WEB_UI_VIEW_INVENTORY_RECORD; do
      grep -qE "${c}([^A-Za-z0-9_]|$)" "$UT" || exit 1
    done'

# GREEN ON DEVELOP ALREADY -- SBDEV-2968 D4 seeded this one (and V2.2.18 covers existing
# tenants). Kept as a regression pin, NOT as a gate: TRANSFER_ORDER is one of the 13
# orphans in the plan's 2.5 table that is already satisfied. Do not re-seed it.
run F2 "TRANSFER_ORDER -> inventory/outbound-manager (2968 D4 pin, green today)" bash -c "
    f='$UT'; [ -f \"\$f\" ] || exit 1
    perl -0777 -ne 'exit 1 unless /grantFunction\(\s*WmsConstants\.FunctionEnum\.WEB_UI_VIEW_TRANSFER_ORDER\s*,[^;]*role_outbound_manager/s' \"\$f\""
# FIXED 2026-08-21 (TDD gate): this row was `grep -c ... -le 2` and was PERMANENTLY RED --
# UtilRestController mentions WEB_UI_VIEW_USER_MANAGEMENT three times (an addFunctionToUser for
# the admin USER, the addFunctionToRole for super-admin, and a third in an unrelated method), so
# the threshold could never be met and the row read as credible, honest-looking work-not-done.
# Bumping the number would just re-break on the next mention. Assert the ASSOCIATION instead:
# no role OTHER than super_admin may be handed this function. That is the actual §2.5 claim, and
# unlike a count it goes red for the right reason -- someone granting it to another persona.
run F3 "USER_MANAGEMENT granted to NO role but super-admin" bash -c "
    f='$UT'; [ -f \"\$f\" ] || exit 1
    # Separate-line form: addFunctionToRole(...USER_MANAGEMENT...), role_X.getId()
    bad=\$(grep -nE 'WEB_UI_VIEW_USER_MANAGEMENT' \"\$f\" \
           | grep -E 'addFunctionToRole|grantFunction' \
           | grep -vE 'role_super_admin')
    [ -n \"\$bad\" ] && exit 1
    # Varargs form the plan steers toward: grantFunction(CONST,\n  role_a, role_b, ...) --
    # the role list can sit on the NEXT line, which a per-line grep cannot see. Lane 3 measured
    # this leak. Pull the whole call and reject any role token that is not role_super_admin.
    perl -0777 -ne '
      while (/grantFunction\(\s*WmsConstants\.FunctionEnum\.WEB_UI_VIEW_USER_MANAGEMENT\s*,(.*?)\)\s*;/gs) {
        my \$args = \$1;
        while (\$args =~ /(role_[A-Za-z0-9_]+)/g) { exit 1 if \$1 ne \"role_super_admin\"; }
      }
      exit 0' \"\$f\""

# Flyway head on develop was V2.2.18 at the time of the split. RE-SWEEP ALL REMOTE
# BRANCHES at PR time — `ls db/migration/` shows a stale head because unmerged
# branches hold invisible versions.
MIG=$(ls "$API/src/main/resources/db/migration/"V2.2.19__*.sql \
         "$API/src/main/resources/db/migration/"V2.2.[2-9][0-9]__*.sql 2>/dev/null | head -1)
export MIG
if [ -n "${MIG:-}" ]; then
  run F4 "VIEW grant migration exists"                    file_exists "$MIG"
  run F5 "  ... idempotent via NOT EXISTS"                file_contains 'NOT EXISTS' "$MIG"
  # Both forms of ON CONFLICT are wrong here, on DIFFERENT subsets of tenants:
  # constraint-name drift (_pkey vs _pk) breaks the named form; base-dump tenants
  # have no unique index at all, so column inference raises 42P10.
  run F6 "  ... no ON CONFLICT (see plan 2.5-F2)" bash -c '
      [ -f "$MIG" ] || exit 1
      ! strip_comments "$MIG" sql | grep -qiE "ON[[:space:]]+CONFLICT"' 
  run F7 "  ... INSERT-only (no ownership trap)"          file_not_contains 'CREATE OR REPLACE' "$MIG"
  run F8 "  ... keyed by role NAME, not id"               file_contains 'mywms_role' "$MIG"
  run F9 "  ... writes the role<->function join table"    file_contains 'mywms_role_mywms_function' "$MIG"
else
  run F4 "VIEW grant migration exists" file_exists "$API/src/main/resources/db/migration/V2.2.MISSING__view_grants.sql"
  for i in 5 6 7 8 9; do skip "F$i" "  ... migration absent"; done
fi

# --------------------------------------------------------------------------
echo; echo "Tests"
# --------------------------------------------------------------------------
run T1 "appMenuList spec exists"          file_exists "$WEB/test/util/appMenuList.spec.js"
run T2 "layout menu-filter spec exists"   file_exists "$WEB/test/layouts/default.spec.js"
run T3 "  ... pins the CS-REP fixture"    file_contains 'csRep|CS-REP' "$WEB/test/layouts/default.spec.js"
run T4 "  ... pins the empty-group case"  file_contains 'hidesAGroupWhenNoChildSurvives' "$WEB/test/layouts/default.spec.js"
run T5 "middleware spec exists"           file_exists "$WEB/test/middleware/requireFunction.spec.js"
run T6 "admin tab spec exists"            file_exists "$WEB/test/pages/admin.spec.js"
run T7 "entry-gate spec exists"           file_exists "$WEB/test/pages/index.spec.js"
run T8 "store commit spec exists"         file_exists "$WEB/test/store/index.spec.js"
run T9 "seed unit test covers the grants" file_exists "$TST/unit/controller/rest/UtilRestControllerSeedUnitTest.java"

# --------------------------------------------------------------------------
echo; echo "Design-review additions (2026-08-21)"
# --------------------------------------------------------------------------
# H (persistence). Two review lanes independently found that root-state functions* ride in the
# vuex-web blob, which is never cleared on logout -> the next user on a shared floor PC rehydrates
# the previous user's full menu and ensureFunctionsLoaded short-circuits without fetching.
# ═══ H1/H2/H3 REPLACED 2026-08-21 (3rd pass). Read this before "improving" them. ═══
# These rows tried twice to assert that the authz state is NOT persisted, and both times certified
# the exact vulnerability they exist to forbid:
#   v1  greped for `functionsLoaded` -- and `functions` is its SUBSTRING, so excluding only the two
#       booleans while still persisting the entitlement ARRAY passed.
#   v2  word-boundary regexes over the reducer region -- MEASURED green against a reducer that
#       EXPLICITLY persists all three keys, because containment cannot tell an exclusion list from an
#       inclusion list, nor live code from `if (false)`.
# The property is behavioural and now lives where behaviour can be observed:
#   test/plugins/persistedStateAuthz.spec.js -- runs the real reducer and inspects what it RETURNS.
# What a grep CAN settle is the testability contract that makes that spec possible, so that is all
# these rows now claim.
run H1 "reducer is EXPORTED so its output can be asserted (see persistedStateAuthz.spec.js)" bash -c '
    [ -f "$PS" ] || exit 1
    grep -qE "^[[:space:]]*export[[:space:]]+(const|function)[[:space:]]+reducer" "$PS"'
run H2 "  ... and that exported reducer is the one passed to createPersistedState" bash -c '
    [ -f "$PS" ] || exit 1
    perl -0777 -ne "exit 1 unless /createPersistedState\(\s*\{[^}]*\breducer\b/s" "$PS"'

# Guard (b)+(c): fail CLOSED, and await the Keycloak barrier. Without (c) the guard is a permanent
# no-op on every page load while every unit test stays green.
run H4 "guard fails CLOSED to /unhealthy-tenant"  bash -c "
    [ -f '$MW' ] || exit 1
    perl -0777 -ne 'exit 1 unless /functionsLoaded[^}]{0,400}unhealthy-tenant/s' '$MW'"
# FIXED 2026-08-21 (2nd pass): the previous regex required a bare `this.$kc.ready` and therefore went
# RED against the CORRECT defensive form `this.$kc?.ready` — $kc is not injected on three plugin
# paths. A row that fails a correct implementation is the worst category there is. Accept both.
run H5 "ensureFunctionsLoaded awaits the Keycloak ready barrier" bash -c '
    f="$WEB/store/index.js"; [ -f "$f" ] || exit 1
    # `self` as well as `this`: a memoised action whose body is an IIFE captures `const self = this`,
    # which is the idiomatic shape here and was predicted by the test-review lane. Demanding `this`
    # alone reds a correct implementation.
    perl -0777 -ne "exit 1 unless /ensureFunctionsLoaded.{0,2500}?await\\s+(this|self)\\.[\\\$]kc\\s*\\??\\.\\s*ready/s" "$f"' 
run H5b "  ... and treats an unresolvable principal as an ERROR, not an empty entitlement" bash -c '
    f="$WEB/store/index.js"; [ -f "$f" ] || exit 1
    # B4-12: mobile has a RECORDED REGRESSION from denying on this branch. It must set the error flag
    # so the user reaches the recoverable page, and must never fetch getAllRoles/undefined.
    perl -0777 -ne "exit 1 unless /ensureFunctionsLoaded.{0,2000}?setFunctionsError/s" "$f" &&
    ! grep -qE "getAllRoles/\\\$\{?(undefined|null)" "$f"'


# Route classification must be EXHAUSTIVE -- an unmapped route defaulting to pass is what made
# /outbound/transfer22 a live bypass of the only gate this slice ships.
run H6 "EXTRA_ROUTES exists"                      file_contains 'EXTRA_ROUTES' "$AML"
run H7 "  ... covers the non-nesting cycleCount detail routes" bash -c "
    [ -f '$AML' ] || exit 1
    grep -q 'internalOps/cycleCount' '$AML'"
run H8 "  ... covers the openNotice/closedNotice routes" bash -c "
    [ -f '$AML' ] || exit 1
    grep -q 'openNotice' '$AML' && grep -q 'closedNotice' '$AML'"
run H9 "/not-affiliated is ungated"               bash -c "
    [ -f '$AML' ] || exit 1
    perl -0777 -ne 'exit 1 unless /UNGATED_ROUTES.{0,400}not-affiliated/s' '$AML'"

# B-25: the six dead/shadow pages. Three were LIVE duplicates of gated pages.
for pg in outbound/transfer22 masterData/strategies/customer-orders reports/data-report \
          masterData/locationData/storage-location_org masterData/strategies/sku-data-nam \
          receiving/lookup; do
  run "D-$(basename $pg)" "  deleted: pages/$pg.vue" bash -c "[ ! -f '$WEB/pages/$pg.vue' ]"
done

# B-22: the landing must not be a hardcoded /dashboard that two granted personas cannot reach.
run H10 "post-login landing is not hardcoded /dashboard" bash -c '
    f="$WEB/pages/index.vue"; [ -f "$f" ] || exit 1
    ! grep -qE "router[.]push[(][[:space:]]*[^)]*/dashboard" "$f"'

# B-21: the tab PANES must iterate the filtered list, not seven hardcoded children.
run H11 "admin panes track visibleTabs"           bash -c "
    f='$WEB/pages/admin.vue'; [ -f \"\$f\" ] || exit 1
    perl -0777 -ne 'exit 1 unless /<v-tabs-items(?:(?!<\/v-tabs-items>).)*v-for(?:(?!<\/v-tabs-items>).)*visibleTabs/s' \"\$f\""

# B-24 / P10: updateFunctionList() has NO reachable caller (UtilRestController is @Service), so a new
# FunctionEnum constant produces no mywms_function row on an existing tenant unless the migration
# inserts one -- and gating row 26 on a rowless function hides it from EVERYONE, super-admin included.
if [ -n "${MIG:-}" ]; then
  # FIXED 2026-08-21 (2nd pass): the previous form was a 600-char PROXIMITY regex, and the
  # join-table GRANT statement names `mywms_function` and the constant ~60 chars apart -- so a
  # migration that grants the rows and never inserts the function row scored PASS. That is defect
  # B-24/P10 shipping green through the row written to catch it (demonstrated by lane 2).
  # Require the INSERT statement SHAPE, bounded to its own statement by the semicolon.
  run H12 "migration INSERTs the mywms_function row for PARCEL_PICKING" bash -c '
      [ -f "$MIG" ] || exit 1
      perl -0777 -ne "exit 1 unless /INSERT\s+INTO\s+mywms_function\b[^;]*WEB_UI_VIEW_PARCEL_PICKING[^;]*;/si" "$MIG"'
  run H12b "  ... and that INSERT precedes the grant statements" bash -c '
      [ -f "$MIG" ] || exit 1
      perl -0777 -ne "
        my \$f = \$_;
        my (\$ins) = \$f =~ /()INSERT\s+INTO\s+mywms_function\b/si ? \$-[0] : -1;
        my (\$grant) = \$f =~ /()INSERT\s+INTO\s+mywms_role_mywms_function\b/si ? \$-[0] : -1;
        exit 1 if \$ins < 0 || \$grant < 0 || \$ins > \$grant;" "$MIG"'
  # FIXED 2026-08-21 (2nd pass): `grep -q WEB_UI_VIEW_STOCK_UNIT` is satisfied by the PREFIX inside
  # WEB_UI_VIEW_STOCK_UNIT_RECORD, so a migration missing the STOCK_UNIT grant scored 5/5 and
  # Handling Units silently hid for a CONTAINER-less user (demonstrated by lane 2). Anchor the
  # trailing boundary so a constant cannot be satisfied by a longer sibling.
  run H13 "  ... and grants the 5 orphans the CS-REP miscount hid" bash -c '
      [ -f "$MIG" ] || exit 1
      for c in WEB_UI_VIEW_CLUB_LINE WEB_UI_VIEW_STOCK_UNIT WEB_UI_VIEW_CONTAINER \
               WEB_UI_VIEW_STOCK_UNIT_RECORD WEB_UI_VIEW_UNIT_LOAD_RECORD; do
        grep -qE "${c}([^A-Za-z0-9_]|$)" "$MIG" || exit 1
      done'
  run H13b "  ... NOT via ON CONFLICT (42P10 on prd, which has neither PK nor unique index)" bash -c '
      [ -f "$MIG" ] || exit 1
      # comment-stripped: this migration EXPLAINS at length why ON CONFLICT is wrong here, and that
      # explanation is the most valuable thing in the file. It must not red the row.
      ! strip_comments "$MIG" sql | grep -qiE "ON[[:space:]]+CONFLICT"' 
else
  skip H12  "  ... migration absent"
  skip H12b "  ... migration absent"
  skip H13  "  ... migration absent"
  skip H13b "  ... migration absent"
fi

echo; echo "Anti-regression"
# --------------------------------------------------------------------------
run R1 "mobile menu filter untouched"        file_contains 'MOBILE_UI_VIEW_INFO' "$PROJECT_ROOT/v2/wms2-mobile-ui/store/home.js"
# FIXED 2026-08-21 (TDD gate): this row was `file_contains IS_WMS_ADMIN AdminController.java`
# and was PERMANENTLY RED -- that string appears in NO controller in the repo. The user-admin
# surface is no longer gated that way: SBDEV-2984 (PR #180, merged) moved it onto
# @RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT) on UserController. Pin what is actually there,
# because THAT is the property slice B must not disturb while it hides the same tab client-side.
run R2 "user-admin writes still gated by WEB_UI_VIEW_USER_MANAGEMENT (SBDEV-2984)" bash -c "
    f='$SRC/controller/UserController.java'; [ -f \"\$f\" ] || exit 1
    n=\$(grep -cE '@RequiresFunction\(WmsConstants\.FunctionEnum\.WEB_UI_VIEW_USER_MANAGEMENT\)' \"\$f\")
    [ \"\$n\" -ge 9 ]"
# This slice is CLIENT-SIDE ONLY (plan 1.3). It must not start annotating web
# controllers for VIEW functions -- that is SBDEV-3017, and about half the surface
# is Spring Data REST, which the interceptor structurally cannot reach anyway.
# FIXED 2026-08-21 (TDD gate): the absolute-zero form was PERMANENTLY RED. Four classes already
# and legitimately carry a WEB_UI_VIEW @RequiresFunction on develop -- UserController,
# UserGroupController and UserRoleController from SBDEV-2984, and mobile/TransferOrderController
# from SBDEV-2968. The row's INTENT is right (slice B is client-side only, §1.3; server-side web
# view gating is SBDEV-3017 and ~14 of ~32 roots are SDR the interceptor cannot reach anyway) --
# so allowlist the known four and fail on any FIFTH. Same shape as the deleted pre-split row's
# lesson: a negative that a merged sibling ticket already violates reads as work-not-done.
run R3 "WEB_UI_VIEW @RequiresFunction confined to the 4 known files, at the known counts" bash -c "
    # Lane 3 measured two holes in the earlier basename allowlist: the string-literal annotation form
    # slipped through, and a NEW annotation added inside an already-known file was invisible. A subset
    # check also cannot see DELETIONS. So: exact relative paths, per-file counts, and a pattern that
    # covers both the constant and the string-literal forms.
    c='$SRC'
    pat='@RequiresFunction\((WmsConstants\.FunctionEnum\.WEB_UI_VIEW|\"WEB_UI_VIEW)'
    expected='controller/UserController.java:9
controller/UserGroupController.java:1
controller/UserRoleController.java:1
controller/mobile/TransferOrderController.java:1'
    actual=\$(grep -rlE \"\$pat\" \"\$c\" 2>/dev/null | while read -r f; do
                printf '%s:%s\n' \"\${f#\$c/}\" \"\$(grep -cE \"\$pat\" \"\$f\")\"
              done | sort)
    [ \"\$actual\" = \"\$(printf '%s' \"\$expected\" | sort)\" ]"

# NOTE: the pre-split row "the 5 shared controllers stay unannotated by this plan"
# was DELETED, not carried over. SBDEV-2968 legitimately annotated StockUnitController
# (transferStock, storageLocationsForStockMovement), so that row can never pass again
# and reads as honest work-not-done. The 2968 annotations are pinned in slice C (C-10).

echo
echo "NOT machine-checkable — these need a named owner, not another script run:"
echo "  · P2/P8  DECIDED 2026-08-21 (Nam): the VIEW grant table ships as drafted, WIDENED by 6 rows"
echo "        after the design review; row 26 gets a new WEB_UI_VIEW_PARCEL_PICKING constant."
echo "  · P3  the per-tenant audit + regression predictor. RUN 2026-08-21 across all 6 tenants:"
echo "        prd is CLEAN (all 7 humans are super-admin); six named wineco wsl UAT operators lose"
echo "        real screens without the widened table. An EMPTY result set is NOT an all-clear --"
echo "        two tenants came back clean ONLY because everyone there is super-admin."
echo "  · P9  DEPLOY GATE: never ship to an env whose api lacks 60aef02 (SBDEV-3005). It is NOT on"
echo "        origin/main. Check: git merge-base --is-ancestor 60aef02 origin/<env-branch>"
echo "  · P13 add lukamiranda to its 6 peer groups on wh01_om1_v2 before the wsl UAT image lands."
echo "  · mutation-check: restore menuList[\"super-admin\"] and confirm the filter specs go RED."
echo "        Also re-check the ANY-of and depth-2 pruning tests -- BOTH were measured as surviving"
echo "        mutants before 2026-08-21, green while the guard denied super-admin every ANY-of route."
echo "  · Jest baseline: develop has 2 always-red SUITES and 0 failing tests. Compare the TESTS"
echo "        count, never the suites count. No yarn on PATH -- use node_modules/.bin/jest."
echo "  · Browser-only: that the guard runs before paint on a hard refresh. No unit test can see the"
echo "        fire-and-forget initKeycloak() race that the \$kc.ready await fixes."
printf "Result: %d pass, %d fail, %d skip\n" "$PASS" "$FAIL" "$SKIP"
echo
[ "$FAIL" -eq 0 ]
