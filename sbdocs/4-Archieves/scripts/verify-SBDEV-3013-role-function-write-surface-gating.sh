#!/usr/bin/env bash
# verify-SBDEV-3013-role-function-write-surface-gating.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-3013-role-function-write-surface-gating.md
#
# SCOPE: door ② only (the controller half). Door ① (Spring Data REST) is phase 2 and
# has no rows here — see the DEFERRED block at the end.
#
# Usage:
#   PROJECT_ROOT=/path/to/owl bash sbdocs/9-System/scripts/verify-SBDEV-3013-...sh
#
# PROJECT_ROOT is MONO-ROOTED — it must contain v2/wms2-api. Against the per-ticket
# worktree, point it at a symlink shadow root or it grades the main checkout.
#
# Run BEFORE any change for the FAIL baseline. Acceptance is "Result: N pass, 0 fail".
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

URC="$SRC/controller/UserRoleController.java"
UGC="$SRC/controller/UserGroupController.java"
ADC="$SRC/controller/AdminController.java"
INT="$SRC/security/FunctionGuardInterceptor.java"
ARCH="$TST/unit/config/FunctionGuardArchTest.java"
WIRE="$TST/unit/security/FunctionGuardWiringUnitTest.java"
GATE="$TST/unit/security/UserAdminFunctionGateUnitTest.java"

echo; echo "SBDEV-3013 door ② — user-admin write surface function gate"; echo "PROJECT_ROOT=$PROJECT_ROOT"; echo

if git -C "$API" rev-parse --verify origin/develop >/dev/null 2>&1; then
  behind=$(git -C "$API" rev-list --count HEAD..origin/develop 2>/dev/null || echo 0)
  if [ "${behind:-0}" -gt 0 ]; then
    echo "  ⚠ $API is $behind commit(s) behind origin/develop — rows asserting SBDEV-2968's"
    echo "    landed surface will red for that reason alone. Fetch/rebase before judging."; echo
  fi
fi

# A class-level annotation must sit on the CLASS, not merely appear in the file. The
# tempered gap `[^;{]*` cannot cross into a member declaration, so it cannot pair the
# annotation with something further down the file.
class_annotated() { # $1=file $2=class $3=constant
  [ -f "$1" ] || return 1
  perl -0777 -ne "exit 1 unless /\@RequiresFunction\([^)]*$3[^)]*\)[^;{]*?public\s+class\s+$2\b/s" "$1"
}

# --------------------------------------------------------------------------
echo "The gate"
# --------------------------------------------------------------------------
run A1 "UserRoleController carries a class-level gate on USER_MANAGEMENT" \
    class_annotated "$URC" "UserRoleController" "WEB_UI_VIEW_USER_MANAGEMENT"
run A2 "UserGroupController carries a class-level gate on USER_MANAGEMENT" \
    class_annotated "$UGC" "UserGroupController" "WEB_UI_VIEW_USER_MANAGEMENT"
# Class-level ALONE does not fail closed: a handler added later with no annotation
# falls through OPEN unless the declaring class is in GUARDED.
run A3 "UserRoleController is in the interceptor's GUARDED set"   file_contains 'UserRoleController\.class'  "$INT"
run A4 "UserGroupController is in the interceptor's GUARDED set"  file_contains 'UserGroupController\.class' "$INT"
run A5 "  ... and the interceptor imports them"                   file_contains 'import net\.aim_ai\.wms\.controller\.UserRoleController' "$INT"

# --------------------------------------------------------------------------
echo; echo "Anti-drift — the golden map and the boot assertion"
# --------------------------------------------------------------------------
run G1 "golden map names UserRoleController"    file_contains 'GOLDEN_MAP\.put\("UserRoleController"'  "$ARCH"
run G2 "golden map names UserGroupController"   file_contains 'GOLDEN_MAP\.put\("UserGroupController"' "$ARCH"
run G3 "wiring test expects both in GUARDED"    bash -c "
    f='$WIRE'; [ -f \"\$f\" ] || exit 1
    grep -q 'UserRoleController\.class' \"\$f\" && grep -q 'UserGroupController\.class' \"\$f\""

# --------------------------------------------------------------------------
echo; echo "Tests"
# --------------------------------------------------------------------------
run T1 "the door-② gate test class exists"                file_exists "$GATE"
run T2 "  ... asserts the declared handler SET (anti-vacuity)" file_contains 'containsExactlyInAnyOrderElementsOf\(USER_ROLE_HANDLERS\)' "$GATE"
run T3 "  ... keys handlers on name + ARITY, not name alone"   file_contains 'getName\(\) \+ "/" \+ .*getParameterCount\(\)' "$GATE"
run T4 "  ... covers all 8 declared endpoints"            bash -c "
    f='$GATE'; [ -f \"\$f\" ] || exit 1
    for m in createRole deletRole saveRoleFunctions userRoleDetailsById create delete saveGroupRoles userGroupDetailsById; do
      grep -q \"\$m\" \"\$f\" || exit 1
    done"
run T5 "  ... tests the ESCALATION CHAIN, not only endpoints" file_contains 'SelfEscalationChain|theSelfEscalationChainFailsAtItsFirstStep' "$GATE"
# The allow-path assertions pass VACUOUSLY on an ungated build unless the test also
# proves AccessService was consulted.
run T6 "  ... the allow path verifies the gate was consulted" file_contains 'verify\(accessService\)\.checkAnyAccess' "$GATE"

# --------------------------------------------------------------------------
echo; echo "Anti-regression"
# --------------------------------------------------------------------------
# AdminController is the base class of 43 controllers. A class-level gate there would
# apply to ALL of them; its own handlers are already @PreAuthorize(IS_SB_ADMIN).
run R1 "AdminController carries NO @RequiresFunction"     file_not_contains '@RequiresFunction' "$ADC"
run R2 "  ... and still carries its IS_SB_ADMIN gates"    file_contains 'IS_SB_ADMIN' "$ADC"
# Anchored at line start so a JAVADOC MENTION of @PreAuthorize does not trip it. The
# unanchored form failed on this very implementation, whose class comment explains why
# AdminController's inherited aliases are @PreAuthorize(IS_SB_ADMIN) — a negative grep
# satisfied by prose is the mirror of a negative satisfied by a comment.
run R3 "the gate is not smuggled in as @PreAuthorize"     bash -c "
    ! grep -qE '^[[:space:]]*@PreAuthorize' '$URC' 2>/dev/null &&
    ! grep -qE '^[[:space:]]*@PreAuthorize' '$UGC' 2>/dev/null"
run R4 "2968's shared StockUnitController gates untouched" bash -c "
    perl -0777 -ne 'exit 1 unless /\@RequiresFunction\([^)]*MOBILE_UI_VIEW_STOCK_TRANSFER[^)]*\)[^{}]*?\btransferStock\s*\(/s' '$SRC/controller/StockUnitController.java'"

echo
echo "DEFERRED — door ① (Spring Data REST), phase 2, deliberately NOT rows here:"
echo "  · POST/DELETE /v3/userRoleUserFunction  ·  PATCH/POST /v3/userRole/{id}/functions"
echo "  RepositoryRestHandlerMapping ignores addInterceptors, so the interceptor cannot"
echo "  reach either. Closing door ② does NOT close the escalation on its own."
echo
echo "NOT machine-checkable:"
echo "  · mutation-check: delete ONE class-level annotation and confirm exactly that"
echo "    controller's 8 parameterized rows go red — not a neighbour's, and not nothing."
echo "  · full suite vs the known 2 pre-existing failures on develop."
echo "  · mvn test MUTATES the tracked archunit_store — revert it before committing."
echo
printf "Result: %d pass, %d fail, %d skip\n" "$PASS" "$FAIL" "$SKIP"
echo
[ "$FAIL" -eq 0 ]
