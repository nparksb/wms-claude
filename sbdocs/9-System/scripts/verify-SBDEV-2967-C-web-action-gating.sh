#!/usr/bin/env bash
# verify-SBDEV-2967-C-web-action-gating.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2967-C-web-action-gating.md
#
# Usage:
#   PROJECT_ROOT=/path/to/owl bash sbdocs/9-System/scripts/verify-SBDEV-2967-C-...sh
#
# PROJECT_ROOT is MONO-ROOTED — it must contain v2/wms2-api and v2/wms2-web-ui.
# Against a per-ticket worktree, point it at a symlink shadow root or it grades the
# main checkout. (37 of 44 verify scripts want the SUB-REPO root; this one does not.)
#
# Run BEFORE any change for the FAIL baseline. Acceptance is "Result: N pass, 0 fail".
#
# ─────────────────────────────────────────────────────────────────────────────
# ⚠ THIS SCRIPT DELIBERATELY DOES NOT INHERIT ROWS E1-E9 FROM THE PRE-SPLIT SCRIPT.
#
# Those rows encoded the SERVICE-layer placement that the plan's own architect review
# had already reversed, and the pre-split plan shipped both instructions at once:
#   · E1-E6 asserted the constants appear in StockunitService/UnitloadService. A correct
#     controller-level implementation leaves those files untouched -> permanent red that
#     reads as honest work-not-done.
#   · E8 pinned ADJUST_LOCK_DAMAGED as "enforcement UNCHANGED (regression pin)". It is
#     NOT enforced on setLockDamaged (plan 0.E) -- following that row ships
#     /transferToDamaged open.
#   · E9 asserted NO WEB_UI_ACTION_* appears inside a @RequiresFunction. That row would
#     FAIL a correct implementation. It is inverted below.
# ─────────────────────────────────────────────────────────────────────────────
#
# Helpers are hardened: the stock template's file_not_contains returns TRUE for a file
# that does not exist, false-greening every negative assertion about a NEW file.
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
# As file_not_contains, but strips SQL line comments first.
#
# 🔴 ADDED 2026-08-22 (SBDEV-2967-C). V2.2.20's header DOCUMENTS why `ON CONFLICT` is wrong on three
# different tenant shapes -- so the literal appears in a comment, and the plain negative grep failed a
# migration that contains no such statement. The mirror-image trap is worse and is already recorded in
# this repo: a comment quoting a forbidden literal can SATISFY a negative grep. Judge statements, not prose.
sql_not_contains(){ [ -f "$2" ] || return 1; ! sed 's/--.*$//' "$2" | grep -qE "$1"; }
file_contains_n()  { [ -f "$2" ] || return 1; local c; c=$(grep -cE "$1" "$2" 2>/dev/null || echo 0); [ "$c" -ge "$3" ]; }
tree_contains()    { [ -d "$2" ] || return 1; grep -rqE "$1" "$2"; }

SUC="$SRC/controller/StockUnitController.java"
ULC="$SRC/controller/UnitLoadController.java"
UT="$SRC/controller/rest/UtilRestController.java"

# Assert an ANNOTATION -> METHOD pair, not mere co-presence in the file. `[^{}]*` is a
# tempered gap: it cannot cross a method body, so it cannot pair an annotation with a
# method defined elsewhere in the class. (An unbounded `.*?` under /s silently matches
# a correct construct ELSEWHERE in the file -> false green.)
gated() { # $1=file $2=constant $3=method
  # The gap must stay TEMPERED so the annotation and the method are provably in the same block --
  # an unbounded .*? would match a correct construct elsewhere in the file and false-green.
  #
  # 🔴 FIXED 2026-08-22 (SBDEV-2967-C). The gap was `[^{}]*?`, which forbids ALL braces -- including
  # the ones inside a mapping path literal. `@GetMapping(path= "/deleteContainerRecursive/{id}")`
  # therefore made row C13 UNMATCHABLE: it reported FAIL for a correctly-gated endpoint, and read as
  # honest work-not-done. Braces are now permitted only INSIDE a double-quoted string, so a real
  # method body `{` still terminates the gap.
  [ -f "$1" ] || return 1
  # 🔴 `[^{}\"]` not `[^{}]` in the plain branch -- CORRECTED 2026-08-22 after the conformance lane
  # measured two false-greens (C6 bulkAdjustReservedAmount, C8 bulkSetLockOnHold). With a bare quote
  # matchable by BOTH branches the engine can enter a string at one quote, swallow braces across a whole
  # method body, and close at a later quote -- so an endpoint whose annotation was DELETED still matched
  # its neighbour's. Excluding the quote forces every `"` to open a complete string literal.
  perl -0777 -ne "exit 1 unless /\@RequiresFunction\([^)]*$2[^)]*\)(?:[^{}\"]|\"[^\"]*\")*?\b$3\s*\(/s" "$1"
}

echo; echo "SBDEV-2967-C — server-side gates for the 8 WEB_UI_ACTION_* constants"; echo "PROJECT_ROOT=$PROJECT_ROOT"; echo

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
echo "Tranche C1 — StockUnitController, 10 endpoints (single AND bulk of each pair)"
# --------------------------------------------------------------------------
# The bulk member is not optional. StockUnitController:224-254 catches BusinessException
# and returns ResponseEntity.ok(errorMap), so a MISPLACED guard on a bulk path yields
# HTTP 200 with an errors array -- indistinguishable from partial success.
for row in \
  "C1:WEB_UI_ACTION_ADJUST_LOCK_DAMAGED:transferToDamaged" \
  "C2:WEB_UI_ACTION_ADJUST_LOCK_DAMAGED:bulkTransferToDamaged" \
  "C3:WEB_UI_ACTION_ADJUST_AMOUNT:adjustAmount" \
  "C4:WEB_UI_ACTION_ADJUST_AMOUNT:bulkAdjustAmount" \
  "C5:WEB_UI_ACTION_ADJUST_RESERVED_AMOUNT:adjustReservedAmount" \
  "C6:WEB_UI_ACTION_ADJUST_RESERVED_AMOUNT:bulkAdjustReservedAmount" \
  "C7:WEB_UI_ACTION_ADJUST_LOCK_ON_HOLD:setLockOnHold" \
  "C8:WEB_UI_ACTION_ADJUST_LOCK_ON_HOLD:bulkSetLockOnHold" \
  "C9:WEB_UI_ACTION_ADJUST_LOCK_RELEASE_LOCK:removeLock" \
  "C10:WEB_UI_ACTION_ADJUST_LOCK_RELEASE_LOCK:bulkRemoveLock" ; do
  id="${row%%:*}"; rest="${row#*:}"; fn="${rest%%:*}"; m="${rest##*:}"
  run "$id" "$m gated by $fn" gated "$SUC" "$fn" "$m"
done

# --------------------------------------------------------------------------
echo; echo "Tranche C1 — UnitLoadController, 3 endpoints"
# --------------------------------------------------------------------------
run C11 "deleteContainer gated"           gated "$ULC" "WEB_UI_ACTION_DELETE_UNIT_LOAD" "deleteContainer"
run C12 "bulkDeleteContainer gated"       gated "$ULC" "WEB_UI_ACTION_DELETE_UNIT_LOAD" "bulkDeleteContainer"
run C13 "deleteContainerRecursive gated"  gated "$ULC" "WEB_UI_ACTION_DELETE_UNIT_LOAD_RECURSIVE" "deleteContainerRecursive"

# --------------------------------------------------------------------------
echo; echo "Placement — the fact that defeats the service layer"
# --------------------------------------------------------------------------
# INVERTED from the pre-split row E9, which asserted the opposite and would have failed
# a correct implementation. Actions ARE gated by the annotation; that is the decision.
run P1 "action gates use @RequiresFunction (the REVERSED decision)" bash -c "
    grep -rqE '@RequiresFunction\([^)]*WEB_UI_ACTION' '$SRC/controller' 2>/dev/null"
# The 7 web-only actions must NOT be re-added at the service layer, where a denial
# becomes HTTP 200 on every bulk path.
run P2 "no NEW service-layer gate for the 7 web-only actions" bash -c "
    for f in '$SRC/service/StockunitService.java' '$SRC/service/UnitloadService.java'; do
      [ -f \"\$f\" ] || continue
      grep -qE 'WEB_UI_ACTION_(ADJUST_AMOUNT|ADJUST_RESERVED_AMOUNT|ADJUST_LOCK_ON_HOLD|ADJUST_LOCK_RELEASE_LOCK|DELETE_UNIT_LOAD)' \"\$f\" && exit 1
    done; exit 0"
# ADJUST_LOCK_DAMAGED is the ONE genuinely cross-UI action: its transferStock branch
# stays at the service layer for the mobile callers. Pin it so a cleanup does not
# remove the mobile half while migrating the web half to the controller.
run P3 "the cross-UI transferStock damaged branch survives" \
    file_contains 'WEB_UI_ACTION_ADJUST_LOCK_DAMAGED' "$SRC/service/StockunitService.java"
# §0.D trap: the delete constants must stop being passed as the `comment` argument.
# 🔴 P4 DOWNGRADED TO AN EXPLICIT DEFERRAL 2026-08-22 (SBDEV-2967-C). This row asserted that the delete
# constants are no longer passed as UnitloadService.deleteUnitLoad's `comment` argument -- but plan 0.D
# calls that "out of scope here -- a data-quality bug, not an authorization one", and 2.4 says outright
# that "the argument gets a real comment, under SBDEV-2979". The row was asserting another ticket's work,
# so it could only ever read as this slice being incomplete. The 2.4 property this slice DOES own -- that
# the gate is not hooked onto that argument -- is covered by P1/P2 and by the annotation contract test.
skip P4 "delete constants still passed as the comment arg -> SBDEV-2979, NOT this slice (plan 0.D/2.4)"
# Header by SYMBOL, never by literal -- so a 2968 revert breaks the BUILD rather than
# silently logging every denied operator out. Mirrors 2968's verify row A27.
run P5 "X-Authz-Denied referenced by symbol, not literal" bash -c "
    ! grep -rq '\"X-Authz-Denied\"' '$SRC/controller' 2>/dev/null"

# --------------------------------------------------------------------------
echo; echo "Golden map + startup assertion (the anti-drift mechanism)"
# --------------------------------------------------------------------------
GM="$TST/unit/config/FunctionGuardArchTest.java"
run G1 "FunctionGuardArchTest exists (from 2968)"        file_exists "$GM"
run G2 "StockUnitController is in the golden map"        file_contains 'StockUnitController' "$GM"
run G3 "UnitLoadController is in the golden map"         file_contains 'UnitLoadController' "$GM"
run G4 "the startup assertion still exists"              file_exists "$SRC/security/FunctionGuardStartupAssertion.java"

# --------------------------------------------------------------------------
echo; echo "Fix F(ACTION) — grants, without which this slice is a silent capability removal"
# --------------------------------------------------------------------------
run F1 "seed grants the adjust actions to inventory-manager (ASSOCIATION)" bash -c "
    f='$UT'; [ -f \"\$f\" ] || exit 1
    for c in WEB_UI_ACTION_ADJUST_AMOUNT WEB_UI_ACTION_ADJUST_RESERVED_AMOUNT; do
      perl -0777 -ne \"exit 1 unless /grantFunction\\(\\s*WmsConstants\\.FunctionEnum\\.\$c\\s*,[^;]*role_inventory_manager/s\" \"\$f\" || exit 1
    done"
run F2 "DELETE_UNIT_LOAD* NOT delegated beyond super-admin" bash -c "
    f='$UT'; [ -f \"\$f\" ] || exit 1
    perl -0777 -ne 'exit 1 if /grantFunction\(\s*WmsConstants\.FunctionEnum\.WEB_UI_ACTION_DELETE_UNIT_LOAD[A-Z_]*\s*,[^;]*role_(inventory|outbound|receiving)/s' \"\$f\""
MIG=$(ls "$API/src/main/resources/db/migration/"V2.2.19__*.sql \
         "$API/src/main/resources/db/migration/"V2.2.[2-9][0-9]__*.sql 2>/dev/null | xargs grep -lE 'WEB_UI_ACTION' 2>/dev/null | head -1)
if [ -n "${MIG:-}" ]; then
  run F3 "ACTION grant migration exists"                 file_exists "$MIG"
  run F4 "  ... idempotent via NOT EXISTS"               file_contains 'NOT EXISTS' "$MIG"
  run F5 "  ... no ON CONFLICT (see plan 2.6)"           sql_not_contains 'ON CONFLICT' "$MIG"
  run F6 "  ... INSERT-only (no ownership trap)"         sql_not_contains 'CREATE OR REPLACE' "$MIG"
  run F7 "  ... keyed by role NAME, not id"              file_contains 'mywms_role' "$MIG"
else
  run F3 "ACTION grant migration exists" file_exists "$API/src/main/resources/db/migration/V2.2.MISSING__action_grants.sql"
  for i in 4 5 6 7; do skip "F$i" "  ... migration absent"; done
fi

# --------------------------------------------------------------------------
echo; echo "Tests"
# --------------------------------------------------------------------------
run T1 "StockUnitController action-guard test exists" bash -c "
    ls '$TST/unit/controller/'*StockUnitController*ActionGuard*.java >/dev/null 2>&1"
run T2 "UnitLoadController action-guard test exists" bash -c "
    ls '$TST/unit/controller/'*UnitLoadController*ActionGuard*.java >/dev/null 2>&1"
run T3 "  ... a denied BULK request asserts 403, not 200" bash -c "
    grep -rqE 'deniedReturns403NotOk|is\(403\)|isForbidden\(\)' '$TST/unit/controller/' 2>/dev/null &&
    grep -rq 'bulk' '$TST/unit/controller/' 2>/dev/null"
run T4 "  ... authorization is read ONCE PER REQUEST on bulk" bash -c "
    grep -rq 'OncePerRequest' '$TST/unit/controller/' 2>/dev/null"
run T5 "seed unit test covers the ACTION grants" bash -c "
    f='$TST/unit/controller/rest/UtilRestControllerSeedUnitTest.java'; [ -f \"\$f\" ] || exit 1
    grep -q 'WEB_UI_ACTION' \"\$f\""
# The single most likely way this slice ships a vacuous suite (plan 4.2).
run T6 "no class-wide lenient() permissive stub in StockUnitControllerUnitTest" bash -c "
    f='$TST/unit/controller/StockUnitControllerUnitTest.java'; [ -f \"\$f\" ] || exit 0
    ! perl -0777 -ne 'exit 1 unless /void\s+setUp\s*\([^)]*\)\s*\{[^}]*lenient\(\)/s' \"\$f\""

# --------------------------------------------------------------------------
echo; echo "Anti-regression"
# --------------------------------------------------------------------------
# 2968 annotated exactly these two shared methods. Gating them WEB_UI-only would 403
# mobile Move Stock for every mobile-only operator.
run R1 "transferStock keeps its 2968 MOBILE ANY-of annotation" bash -c "
    perl -0777 -ne 'exit 1 unless /\@RequiresFunction\([^)]*MOBILE_UI_VIEW_STOCK_TRANSFER[^)]*\)[^{}]*?\btransferStock\s*\(/s' '$SUC'"
# NOTE: the METHOD is getStorageLocationsForStockMovement. The plan's prose (and the
# pre-split plan's) quotes "storageLocationsForStockMovement", which is the URL PATH.
# Keying on the path name here would be a permanent red reading as honest work-not-done.
run R2 "getStorageLocationsForStockMovement keeps its 2968 annotation" bash -c "
    perl -0777 -ne 'exit 1 unless /\@RequiresFunction\([^)]*MOBILE_UI_VIEW_STOCK_TRANSFER[^)]*\)[^{}]*?\bgetStorageLocationsForStockMovement\s*\(/s' '$SUC'"
run R3 "no WEB_UI_ACTION_* gate lands on the two shared methods" bash -c "
    ! perl -0777 -ne 'exit 1 unless /\@RequiresFunction\([^)]*WEB_UI_ACTION[^)]*\)[^{}]*?\b(transferStock|getStorageLocationsForStockMovement)\s*\(/s' '$SUC'"
# Path is service/mobile/, NOT service/. Getting this wrong is a permanent red.
run R4 "mobile services keep their damaged-lock checks" bash -c "
    grep -q 'WEB_UI_ACTION_ADJUST_LOCK_DAMAGED' '$SRC/service/mobile/MobileMoveStockService.java' &&
    grep -q 'WEB_UI_ACTION_ADJUST_LOCK_DAMAGED' '$SRC/service/mobile/MobileMoveUnitloadService.java'"

# --------------------------------------------------------------------------
echo; echo "UI — disabled controls (plan 2.5)"
# --------------------------------------------------------------------------
run U1 "stock-unit store knows the action functions" file_contains 'WEB_UI_ACTION_' "$WEB/store/handlingUnits/stockUnits.js"
run U2 "container store knows the delete function"   file_contains 'WEB_UI_ACTION_DELETE_UNIT_LOAD' "$WEB/store/handlingUnits/container.js"

# --------------------------------------------------------------------------
echo; echo "Guard rails — the OMS path is safe only while these ABSENCES hold (plan 2.7)"
# --------------------------------------------------------------------------
# /rest/** is permitAll (SecurityConfiguration:123-127), so OMS calls arrive with no
# Authentication and record as the sentinel "anonymous". They ARE HTTP and the interceptor
# IS on /** (WebConfig:35) — they fall through ONLY because no rest controller is annotated
# or GUARDED. One annotation added later breaks OMS integration SILENTLY: no suite exercises
# that path. G-1/G-2 pin the absence; G-3 pins the data half.
run GR1 "no controller/rest/* class carries @RequiresFunction" bash -c "
    d='$SRC/controller/rest'; [ -d \"\$d\" ] || exit 1
    ! grep -rq '@RequiresFunction' \"\$d\" 2>/dev/null"
run GR2 "no controller/rest/* class appears in GUARDED" bash -c "
    f='$SRC/security/FunctionGuardInterceptor.java'; [ -f \"\$f\" ] || exit 1
    ! grep -nE '^\\s*[A-Za-z0-9_]*RestController[A-Za-z0-9_]*\\.class,?\\s*\$' \"\$f\" 2>/dev/null &&
    ! grep -q 'controller\\.rest\\.' \"\$f\" 2>/dev/null"
run GR2b "  ... and the ArchUnit rule for G-1/G-2 exists"  bash -c "
    f='$TST/unit/config/FunctionGuardArchTest.java'; [ -f \"\$f\" ] || exit 1
    grep -qE 'controller\\.rest|controller/rest' \"\$f\""
run GR3 "an audit asserts 'anonymous' holds zero functions" bash -c "
    grep -rqE \"anonymous\" '$API/src/main/resources/db/audit-access-invariants.sql' 2>/dev/null ||
    grep -rqE \"anonymous\" '$API/db/audit-access-invariants.sql' 2>/dev/null"

echo
echo "DEFERRED to tranche C2 — deliberately NOT rows here (plan 0.F):"
echo "  · PRINT_TOTE_LABELS: 4 write endpoints across DashboardController, ReportController"
echo "    and LabelPrintingController, no existing consumer, no clean single/bulk shape,"
echo "    and coupled to slice B's undecided row-26. Bundling it holds up the other seven."
echo
echo "NOT machine-checkable — these need a named owner:"
echo "  · P2  slice A merged AND deployed. Without it every gate here logs the operator out."
echo "  · P3  Brent's sign-off on the ACTION grant table (plan 2.6)"
echo "  · P4  the per-tenant regression predictor FOR ACTIONS, not just menu items"
echo "  · mutation-check EACH gate individually: delete one annotation, confirm exactly"
echo "    that endpoint's pair goes red -- not a neighbour's, and not nothing at all."
echo "    A pin can be vacuous even AFTER the fix if a sibling early-return absorbs it."
echo
printf "Result: %d pass, %d fail, %d skip\n" "$PASS" "$FAIL" "$SKIP"
echo
[ "$FAIL" -eq 0 ]
