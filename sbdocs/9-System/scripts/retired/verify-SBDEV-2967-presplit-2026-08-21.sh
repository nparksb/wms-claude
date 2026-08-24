#!/usr/bin/env bash
# verify-SBDEV-2967-web-ui-function-gating-enforcement.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2967-web-ui-function-gating-enforcement.md
#
# Usage:
#   PROJECT_ROOT=/path/to/owl bash sbdocs/9-System/scripts/verify-SBDEV-2967-...sh
#
# PROJECT_ROOT must contain v2/wms2-web-ui and v2/wms2-api. Against a per-ticket
# worktree, point it at a symlink shadow root or it grades the main checkout.
#
# Run BEFORE any change for the FAIL baseline. Acceptance is "Result: N pass, 0 fail".
#
# HELPERS ARE HARDENED DELIBERATELY (sbdocs memory
# "verify-script-template-perl-helpers-fail-open"): the stock template's
# file_not_contains is `! grep ...`, which returns TRUE for a file that does not
# exist — so every negative assertion about a NEW file false-greens. Each helper
# below requires the file to exist first.

set -uo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
WEB="$PROJECT_ROOT/v2/wms2-web-ui"
API="$PROJECT_ROOT/v2/wms2-api"
SRC="$API/src/main/java/net/aim_ai/wms"
TST="$API/src/test/java/net/aim_ai/wms"

PASS=0; FAIL=0; SKIP=0
run() { local id=$1 d=$2; shift 2
  if "$@" >/dev/null 2>&1; then printf "  PASS  %-9s %s\n" "$id" "$d"; PASS=$((PASS+1))
  else printf "  FAIL  %-9s %s\n" "$id" "$d"; FAIL=$((FAIL+1)); fi; }
skip() { printf "  SKIP  %-9s %s\n" "$1" "$2"; SKIP=$((SKIP+1)); }

file_exists()      { [ -f "$1" ]; }
dir_exists()       { [ -d "$1" ]; }
file_contains()    { [ -f "$2" ] || return 1; grep -qE "$1" "$2"; }
file_not_contains(){ [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }
file_contains_n()  { [ -f "$2" ] || return 1; local c; c=$(grep -cE "$1" "$2" 2>/dev/null || echo 0); [ "$c" -ge "$3" ]; }
tree_contains()    { [ -d "$2" ] || return 1; grep -rqE "$1" "$2"; }

echo; echo "SBDEV-2967 — web UI function-gating enforcement"; echo "PROJECT_ROOT=$PROJECT_ROOT"; echo

# --------------------------------------------------------------------------
echo "Fix A — the menu filter"
# --------------------------------------------------------------------------
MENU="$WEB/util/appMenuList.js"
LAYOUT="$WEB/layouts/default.vue"
STORE="$WEB/store/index.js"

run A1 "appMenuList.js exists"                                   file_exists "$MENU"
# THE headline defect: the menu must no longer be hardcoded to the super-admin key.
run A2 "links() no longer hardcodes menuList[\"super-admin\"]"   file_not_contains 'menuList\[.super-admin.\]' "$LAYOUT"
run A3 "links() filters against the user's functions"            file_contains 'functions|\.filter\(' "$LAYOUT"
run A4 "the 4 dead persona menus are gone"                       bash -c "
    [ -f '$MENU' ] || exit 1
    for k in inventory-manager outbound-manager receiving 'outbound-manager,receiving'; do
      grep -qE \"^\\s*'\$k':\" '$MENU' && exit 1
    done; exit 0"
run A5 "every menu leaf declares a fn"                           bash -c "
    [ -f '$MENU' ] || exit 1
    to=\$(grep -cE \"^\\s*to:\" '$MENU'); fn=\$(grep -cE \"^\\s*fn:\" '$MENU')
    [ \"\$to\" -gt 0 ] && [ \"\$fn\" -ge \"\$to\" ]"
run A6 "menu references WEB_UI_ constants (not bare strings)"    file_contains 'WEB_UI_VIEW_' "$MENU"
run A7 "store commits the fetched functions"                     file_contains "commit\(.set(Functions|UserFunctions)" "$STORE"
run A8 "store exposes ensureFunctionsLoaded"                     file_contains 'ensureFunctionsLoaded' "$STORE"
run A9 "  ... getUserRoles no longer discards its result"        file_not_contains 'console\.log\(.getUserRoles:., results\.length\)\s*$' "$STORE"

# --------------------------------------------------------------------------
echo; echo "Fix B — route guard"
# --------------------------------------------------------------------------
run B1 "middleware/ directory exists"                            dir_exists "$WEB/middleware"
run B2 "require-function middleware exists"                      file_exists "$WEB/middleware/require-function.js"
run B3 "  ... awaits ensureFunctionsLoaded before deciding"      file_contains 'ensureFunctionsLoaded' "$WEB/middleware/require-function.js"
run B4 "  ... redirects to /not-authorized"                      file_contains 'not-authorized' "$WEB/middleware/require-function.js"
run B5 "  ... handles the fetch-failure state separately"        file_contains 'unhealthy-tenant|functionsError' "$WEB/middleware/require-function.js"
run B6 "middleware registered in nuxt.config.js"                 file_contains 'require-function' "$WEB/nuxt.config.js"

# --------------------------------------------------------------------------
echo; echo "Fix C — WEB_UI_LOG_IN entry gate"
# --------------------------------------------------------------------------
run C1 "WEB_UI_LOG_IN checked on entry"                          tree_contains 'WEB_UI_LOG_IN' "$WEB/pages"
run C2 "  ... or in the middleware"                              bash -c "
    grep -rqE 'WEB_UI_LOG_IN' '$WEB/pages' '$WEB/middleware' 2>/dev/null"

# --------------------------------------------------------------------------
echo; echo "Fix D — admin tabs"
# --------------------------------------------------------------------------
ADMIN="$WEB/pages/admin.vue"
run D1 "admin tabs are no longer a bare string array"            file_not_contains "tabs: \[\s*$" "$ADMIN"
run D2 "admin tabs carry functions"                              file_contains 'WEB_UI_VIEW_USER_MANAGEMENT' "$ADMIN"
run D3 "  ... System Management → IMPORT_DATA"                   file_contains 'WEB_UI_VIEW_IMPORT_DATA' "$ADMIN"
run D4 "  ... Parameters → SYSTEM_PROPERTY"                      file_contains 'WEB_UI_VIEW_SYSTEM_PROPERTY' "$ADMIN"
run D5 "  ... Printer Setup → PRINTER"                           file_contains 'WEB_UI_VIEW_PRINTER' "$ADMIN"
run D6 "  ... Service Log → MESSAGES"                            file_contains 'WEB_UI_VIEW_MESSAGES' "$ADMIN"
run D7 "  ... Shippers → CLIENT"                                 file_contains 'WEB_UI_VIEW_CLIENT' "$ADMIN"

# --------------------------------------------------------------------------
echo; echo "Fix E — the 8 action gates (SERVICE layer, not the interceptor)"
# --------------------------------------------------------------------------
for pair in \
  "E1:WEB_UI_ACTION_DELETE_UNIT_LOAD:UnitloadService.java" \
  "E2:WEB_UI_ACTION_DELETE_UNIT_LOAD_RECURSIVE:UnitloadService.java" \
  "E3:WEB_UI_ACTION_ADJUST_AMOUNT:StockunitService.java" \
  "E4:WEB_UI_ACTION_ADJUST_RESERVED_AMOUNT:StockunitService.java" \
  "E5:WEB_UI_ACTION_ADJUST_LOCK_RELEASE_LOCK:StockunitService.java" \
  "E6:WEB_UI_ACTION_ADJUST_LOCK_ON_HOLD:StockunitService.java" ; do
  id="${pair%%:*}"; rest="${pair#*:}"; fn="${rest%%:*}"; svc="${rest##*:}"
  run "$id" "$fn guarded in $svc" bash -c "
      f='$SRC/service/$svc'; [ -f \"\$f\" ] || exit 1
      grep -qE 'doesUserHaveAnyAccess|doesUserHaveAccess' \"\$f\" && grep -q '$fn' \"\$f\""
done
run E7 "PRINT_TOTE_LABELS guarded in LabelPrintingService" bash -c "
    f='$SRC/service/LabelPrintingService.java'; [ -f \"\$f\" ] || exit 1
    grep -q 'WEB_UI_ACTION_PRINT_TOTE_LABELS' \"\$f\""
run E8 "ADJUST_LOCK_DAMAGED enforcement is UNCHANGED (regression pin)" \
    file_contains 'WEB_UI_ACTION_ADJUST_LOCK_DAMAGED' "$SRC/service/StockunitService.java"
# Actions must NOT be gated via the interceptor annotation — they are cross-UI.
run E9 "no WEB_UI_ACTION_* used inside a @RequiresFunction" bash -c "
    ! grep -rqE '@RequiresFunction\([^)]*WEB_UI_ACTION' '$SRC' 2>/dev/null"
# §0.C trap: the delete constants must stop being passed as the `comment` argument.
run E10 "delete constants no longer passed as the comment arg" \
    file_not_contains 'deleteUnitLoad(Recursive)?\(unitLoad,\s*WmsConstants\.FunctionEnum' "$SRC/controller/UnitLoadController.java"

# --------------------------------------------------------------------------
echo; echo "Fix F — grant seed + migration"
# --------------------------------------------------------------------------
UT="$SRC/controller/rest/UtilRestController.java"
run F1 "seed grants master data to inventory-manager" bash -c "
    f='$UT'; [ -f \"\$f\" ] || exit 1
    for c in WEB_UI_VIEW_STORAGE_LOCATION WEB_UI_VIEW_ITEM_DATA WEB_UI_VIEW_SECTION WEB_UI_VIEW_AREA; do
      grep -q \"\$c.*role_inventory_manager\\|role_inventory_manager.*\$c\" \"\$f\" || exit 1
    done"
run F2 "seed grants TRANSFER_ORDER to outbound-manager" bash -c "
    grep -q 'WEB_UI_VIEW_TRANSFER_ORDER.*role_outbound_manager\|role_outbound_manager.*WEB_UI_VIEW_TRANSFER_ORDER' '$UT'"
run F3 "USER_MANAGEMENT still granted ONLY to super-admin (+ the admin user)" bash -c "
    f='$UT'; [ -f \"\$f\" ] || exit 1
    n=\$(grep -c 'WEB_UI_VIEW_USER_MANAGEMENT' \"\$f\"); [ \"\$n\" -le 2 ]"
MIG=$(ls "$API/src/main/resources/db/migration/"V2.2.1[89]__*.sql "$API/src/main/resources/db/migration/"V2.2.[2-9][0-9]__*.sql 2>/dev/null | head -1)
if [ -n "${MIG:-}" ]; then
  run F4 "grant migration exists"                       file_exists "$MIG"
  run F5 "  ... idempotent via NOT EXISTS"              file_contains 'NOT EXISTS' "$MIG"
  run F6 "  ... no ON CONFLICT (no unique constraint)"  file_not_contains 'ON CONFLICT' "$MIG"
  run F7 "  ... INSERT-only (no ownership trap)"        file_not_contains 'CREATE OR REPLACE' "$MIG"
  run F8 "  ... keyed by role NAME"                     file_contains 'mywms_role' "$MIG"
else
  run F4 "grant migration exists" file_exists "$API/src/main/resources/db/migration/V2.2.MISSING__grants.sql"
  for i in 5 6 7 8; do skip "F$i" "  ... migration absent"; done
fi

# --------------------------------------------------------------------------
echo; echo "Tests"
# --------------------------------------------------------------------------
run T1 "appMenuList spec exists"          file_exists "$WEB/test/util/appMenuList.spec.js"
run T2 "layout menu-filter spec exists"   file_exists "$WEB/test/layouts/default.spec.js"
run T3 "  ... pins the CS-REP fixture"    file_contains 'csRep|CS-REP' "$WEB/test/layouts/default.spec.js"
run T4 "middleware spec exists"           file_exists "$WEB/test/middleware/requireFunction.spec.js"
run T5 "admin tab spec exists"            file_exists "$WEB/test/pages/admin.spec.js"
run T6 "store commit spec exists"         file_exists "$WEB/test/store/index.spec.js"
run T7 "action-guard unit test exists"    bash -c "
    ls '$TST/unit/service/'*ActionGuard*Test.java >/dev/null 2>&1"
run T8 "seed unit test covers the grants"  bash -c "
    f=\$(ls '$TST/unit/controller/rest/UtilRestControllerSeedUnitTest.java' 2>/dev/null); [ -n \"\$f\" ]"

# --------------------------------------------------------------------------
echo; echo "Anti-regression"
# --------------------------------------------------------------------------
run R1 "mobile menu filter untouched"        file_contains 'MOBILE_UI_VIEW_INFO' "$PROJECT_ROOT/v2/wms2-mobile-ui/store/home.js"
run R2 "the 5 shared controllers stay unannotated by this plan" bash -c "
    ! grep -qE '@RequiresFunction' '$SRC/controller/StockUnitController.java' 2>/dev/null &&
    ! grep -qE '@RequiresFunction' '$SRC/controller/DashboardController.java' 2>/dev/null"
run R3 "AdminController user-admin gates still on wms_admin"  file_contains 'IS_WMS_ADMIN' "$SRC/controller/AdminController.java"

echo
printf "Result: %d pass, %d fail, %d skip\n" "$PASS" "$FAIL" "$SKIP"
echo
[ "$FAIL" -eq 0 ]
