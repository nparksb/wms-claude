#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# BASH >= 4 REQUIRED — hard gate, added 2026-08-19.
# The golden-map section uses `declare -A` (associative arrays), which macOS's
# stock /bin/bash 3.2 does not support. Without this gate the script aborted at
# that line under `set -u` with a bare "mobile: unbound variable" and STILL
# EXITED having graded nothing past it — a partial run that reads like a real
# one. Fail loudly and early instead: a verify script that silently skips two
# thirds of its rows is worse than no verify script.
# ---------------------------------------------------------------------------
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "FATAL: this script needs bash >= 4 (found ${BASH_VERSION:-unknown})." >&2
  echo "       macOS ships bash 3.2; install a modern bash and re-run, e.g." >&2
  echo "         brew install bash && /opt/homebrew/bin/bash $0" >&2
  echo "       Refusing to run: rows past the golden-map section would be" >&2
  echo "       silently skipped and the summary would understate the work." >&2
  exit 2
fi
# verify-SBDEV-2968-mobile-ui-function-gating-enforcement.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2968-mobile-ui-function-gating-enforcement.md
#
# Usage:
#   PROJECT_ROOT=/path/to/owl bash sbdocs/9-System/scripts/verify-SBDEV-2968-...sh
#
# PROJECT_ROOT must point at the root that contains v2/wms2-api and v2/wms2-mobile-ui.
# When running against a per-ticket worktree, point it at a symlink shadow root —
# otherwise this grades the main checkout instead of the work.
#
# Run BEFORE any code change to capture the FAIL baseline, and again after each
# cluster of changes. Final acceptance is "Result: N pass, 0 fail".
#
# NOTE ON HELPERS (deliberate hardening — see sbdocs memory
# "verify-script-template-perl-helpers-fail-open"): the stock template's
# file_not_contains is `! grep ...`, which returns TRUE for a file that does not
# exist, so every negative assertion about a NEW file false-greens. Every helper
# below requires the file to exist first.

set -uo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
API="$PROJECT_ROOT/v2/wms2-api"
MOB="$PROJECT_ROOT/v2/wms2-mobile-ui"
SRC="$API/src/main/java/net/aim_ai/wms"
TST="$API/src/test/java/net/aim_ai/wms"

PASS=0; FAIL=0; SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-9s %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-9s %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}
skip() { printf "  SKIP  %-9s %s\n" "$1" "$2"; SKIP=$((SKIP+1)); }

# --- hardened helpers: every one fails CLOSED on a missing file -------------
file_exists()      { [ -f "$1" ]; }
dir_exists()       { [ -d "$1" ]; }
file_contains()    { [ -f "$2" ] || return 1; grep -qE "$1" "$2"; }
file_not_contains(){ [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }
file_contains_n()  { [ -f "$2" ] || return 1; local c; c=$(grep -cE "$1" "$2" 2>/dev/null || echo 0); [ "$c" -ge "$3" ]; }
# grep across a directory; fails closed if the dir is absent
tree_contains()    { [ -d "$2" ] || return 1; grep -rqE "$1" "$2"; }
tree_not_contains(){ [ -d "$2" ] || return 1; ! grep -rqE "$1" "$2"; }
# Absence assertions must ignore COMMENTS. This has produced a false result six times on this ticket alone
# (S4, S5, E3, E6, F2, T1): a file that DOCUMENTS why a construct is forbidden contains that construct's
# name, so a bare grep reads the warning as the violation — or, worse, reads a comment saying "we do NOT do
# X" as evidence that X is present. Strips //-, #- and *-style line comments before matching.
file_not_contains_code(){
  [ -f "$2" ] || return 1
  ! grep -vE '^[[:space:]]*(//|#|\*|/\*)' "$2" | grep -qE "$1"
}

echo
echo "SBDEV-2968 — mobile UI function-gating enforcement"
echo "PROJECT_ROOT=$PROJECT_ROOT"
echo

# ---------------------------------------------------------------------------
echo "Fix A — the annotation and the interceptor"
# ---------------------------------------------------------------------------
ANN="$SRC/security/RequiresFunction.java"
ITC="$SRC/security/FunctionGuardInterceptor.java"
DEC="$SRC/security/AccessDecision.java"

run A1  "RequiresFunction annotation exists"                     file_exists "$ANN"
run A2  "  ... is @Retention(RUNTIME)"                           file_contains 'RetentionPolicy\.RUNTIME' "$ANN"
run A3  "  ... targets TYPE and METHOD"                          file_contains 'ElementType\.TYPE' "$ANN"
run A4  "  ... declares String[] value()"                        file_contains 'String\[\]\s+value\(\)' "$ANN"
run A5  "FunctionGuardInterceptor exists"                  file_exists "$ITC"
run A6  "  ... implements HandlerInterceptor"                    file_contains 'implements\s+HandlerInterceptor' "$ITC"
run A7  "  ... uses jakarta.servlet (never javax)"               file_contains 'jakarta\.servlet' "$ITC"
run A8  "  ... does NOT import javax.servlet"                    file_not_contains 'import\s+javax\.servlet' "$ITC"
# The single most important line in the change: declaring-class, not bean-type.
run A9  "  ... resolves on getMethod().getDeclaringClass()"      file_contains 'getMethod\(\)\s*\.\s*getDeclaringClass\(\)' "$ITC"
run A10 "  ... does NOT resolve on getBeanType()"                file_not_contains 'getBeanType\(\)\s*[,)]?\s*$|findAnnotation\(\s*hm\.getBeanType\(\)' "$ITC"
run A11 "  ... never calls response.reset() (CORS strip)"        file_not_contains '\.reset\(\)' "$ITC"
run A12 "  ... returns 403 on deny"                              file_contains 'SC_FORBIDDEN|HttpStatus\.FORBIDDEN|\b403\b' "$ITC"
run A13 "AccessDecision record exists"                           file_exists "$DEC"
run A14 "  ... carries all four reasons"                         file_contains 'USER_NOT_PROVISIONED' "$DEC"
run A15 "  ... distinguishes NO_FUNCTIONS from MISSING_FUNCTION" file_contains 'NO_FUNCTIONS' "$DEC"
run A16 "AccessService gains doesUserHaveAnyAccess"              file_contains 'doesUserHaveAnyAccess' "$SRC/service/AccessService.java"
run A17 "AccessService gains checkAnyAccess"                     file_contains 'checkAnyAccess' "$SRC/service/AccessService.java"
run A18 "  ... existing doesUserHaveAccess is retained"          file_contains 'public\s+boolean\s+doesUserHaveAccess' "$SRC/service/AccessService.java"
run A19 "  ... no bare @Transactional added (wrong TM trap)"     file_not_contains '^\s*@Transactional\s*$' "$SRC/service/AccessService.java"
# ⚠️ TIGHTENED 2026-08-20 after the independent review. The old row was
#   file_contains 'FunctionGuardInterceptor|addInterceptor'
# which a mutant that changed the path pattern to something never-matching RETAINS — so this row stayed
# green while the entire gate was switched off (and so did all 100 unit tests). Assert the pattern too,
# and assert the behavioural pin exists, because a grep can never prove the registration actually matches.
run A20 "Interceptor registered in WebConfig"                    file_contains 'FunctionGuardInterceptor|addInterceptor' "$SRC/WebConfig.java"
run A20a "  ... for /** (not a narrowed or never-matching pattern)" bash -c "
    [ -f '$SRC/WebConfig.java' ] || exit 1
    grep -q 'addPathPatterns(\"/\*\*\")' '$SRC/WebConfig.java'"
run A20b "  ... and a test PINS the registration behaviourally"    file_exists "$TST/unit/security/FunctionGuardWiringUnitTest.java"
# ⚠️ TIGHTENED AGAIN 2026-08-21. A20c and A20d were bare token greps over the test file, and both were
# satisfiable by PROSE: A20c went green off `{@link MappedInterceptor}` in a javadoc plus the import line, and
# A20d off a comment merely naming the method. Measured: with the test class body replaced by a single comment
# — javadoc and imports kept, ZERO assertions left — A20b and A20c both still PASSED. Worse, weakening both
# `containsExactlyInAnyOrderElementsOf` calls to `containsAnyElementsOf` while leaving the old name in a
# trailing comment kept verify at 129/0/2, after which GUARDED could be trimmed from eleven to ten with the
# suite 6/6 green — the exact §3.1-A8 regression the pin exists to prevent.
#
# Both rows now strip comments before grepping and require the token in a CALL position, so prose cannot
# satisfy them. `strip_comments` removes // line comments and /* */ blocks.
# ⚠️ Comments are filtered LINE-WISE, not with a /\*...\*/ regex, and both details are load-bearing.
#   (1) A `strip_comments` shell function does not work: `bash -c` spawns a shell that does NOT inherit
#       functions, so it is undefined in the child and bash's exit 127 records as an ordinary FAIL — a
#       permanently red row indistinguishable from real work-not-done. It fired on the first attempt here.
#   (2) A regex comment-stripper does not work either: this very test file contains the STRING LITERAL
#       "/**" (the path pattern), whose `/*` opens a fake comment that a lazy `.*?` under /s closes many
#       lines later, deleting the real assertions along with it. Measured: it silently zeroed the matches
#       and reddened all three rows against correct code.
# Dropping lines that START with //, * or /* removes javadoc bodies and line comments — which is exactly
# where the prose that used to satisfy these rows lived — and cannot be fooled by a string literal.
NOCOMMENT="grep -vE '^[[:space:]]*(//|\*|/\*)'"

run A20c "  ... by CALLING MappedInterceptor.matches (not naming it in a javadoc)" bash -c "
    f='$TST/unit/security/FunctionGuardWiringUnitTest.java'
    [ -f \"\$f\" ] || exit 1
    $NOCOMMENT \"\$f\" | grep -qE '\.matches\(' \
      && $NOCOMMENT \"\$f\" | grep -qE 'MappedInterceptor(\.class|::)'"
run A20d "  ... and pins the GUARDED set by EQUALITY against the expected eleven" bash -c "
    f='$TST/unit/security/FunctionGuardWiringUnitTest.java'
    [ -f \"\$f\" ] || exit 1
    $NOCOMMENT \"\$f\" | grep -qE '\.containsExactlyInAnyOrderElementsOf\(\s*EXPECTED_GUARDED\s*\)'"
# The pin above compares GUARDED to the test's own EXPECTED_GUARDED, so trimming BOTH to ten keeps it green.
# Count the production set independently: eleven class literals inside FunctionGuardInterceptor's Set.of(...).
run A20e "  ... and the production GUARDED set still names ELEVEN controllers" bash -c "
    f='$SRC/security/FunctionGuardInterceptor.java'
    [ -f \"\$f\" ] || exit 1
    n=\$($NOCOMMENT \"\$f\" | perl -0777 -ne 'if (/GUARDED\s*=\s*Set\.of\((.*?)\);/s) { my \$c = () = \$1 =~ /\w+Controller\.class/g; print \$c }')
    [ \"\$n\" = 11 ]"

# A8 in the plan: explicit guarded set + startup assertion
STARTUP="$SRC/security/FunctionGuardStartupAssertion.java"
run A21 "Startup assertion class exists"                         file_exists "$STARTUP"
run A22 "  ... is a SmartInitializingSingleton"                  file_contains 'SmartInitializingSingleton' "$STARTUP"
run A23 "  ... walks RequestMappingHandlerMapping"               file_contains 'RequestMappingHandlerMapping' "$STARTUP"

# ---------------------------------------------------------------------------
echo
echo "Fix A2b — the X-Authz-Denied contract (owned HERE since 2026-08-17)"
# ---------------------------------------------------------------------------
# Plan §3.1-A2b / §14-Δ1. These rows did not exist while the plan believed
# SBDEV-2870 already shipped the header; 2870 PR #166 reverted it (2870 §11.4)
# and this plan lands BEFORE SBDEV-2967, so nothing else will build it.
#
# ⚠ A24-A27 are the whole reason this cluster exists: a header with no CORS
# entry is invisible to the browser and P10's retryCondition fix is inert.
#
# NONE of these rows proves the browser can actually READ it, and no row ever
# will — MockMvc installs no CorsFilter. Nor could a curl row: curl is not
# subject to CORS header filtering, so it reads the header whether or not it is
# exposed. (The DevTools Network panel has the same blind spot — CORS restricts
# what JavaScript may read, not what tools display.) The only discriminating
# check is JS calling headers.get() in a browser, which is M23 in the plan's
# manual matrix. Do not "improve" this script by adding a curl row here; it
# would be a row that cannot fail in the way that matters.
AUTH="$SRC/Authority.java"
SECCFG="$SRC/SecurityConfiguration.java"
run A24 "Authority declares AUTHZ_DENIED_HEADER"                 file_contains 'AUTHZ_DENIED_HEADER' "$AUTH"
run A25 "  ... with the literal X-Authz-Denied"                  file_contains '"X-Authz-Denied"' "$AUTH"
run A26 "Interceptor emits the header on deny"                   file_contains 'AUTHZ_DENIED_HEADER' "$ITC"
# Constant reference, not a re-typed literal — one definition, three consumers.
run A27 "  ... by constant reference, not a bare literal"        file_not_contains '"X-Authz-Denied"' "$ITC"
run A28 "SecurityConfiguration exposes it via CORS"              file_contains 'AUTHZ_DENIED_HEADER' "$SECCFG"
# ⚠ A29 and A31 PASS on the unfixed tree by design — they are regression pins on
# the SBDEV-2632 shape this cluster must reuse, not evidence of this ticket's work.
# A28/A30 are the rows that actually move. Do not read a green A29 as progress.
run A29 "  ... additively (addExposedHeader, not setExposedHeaders) [pre-passes]" \
    file_contains 'addExposedHeader' "$SECCFG"
# The SBDEV-2632 de-duplication guard must wrap the NEW header too, not just
# EXPORT_SKIPPED_HEADER — addExposedHeader does not de-duplicate.
run A30 "  ... behind a contains() de-duplication guard"         bash -c "
    [ -f '$SECCFG' ] || exit 1
    grep -A3 'AUTHZ_DENIED_HEADER' '$SECCFG' | grep -q 'contains' ||
    grep -B3 'AUTHZ_DENIED_HEADER' '$SECCFG' | grep -q 'contains'"
# Pre-existing SBDEV-2632 header must survive — this cluster must not replace it.
run A31 "  ... EXPORT_SKIPPED_HEADER still exposed (no regression) [pre-passes]" \
    file_contains 'EXPORT_SKIPPED_HEADER' "$SECCFG"

# ---------------------------------------------------------------------------
echo
echo "Fix A8 — OrderCancellationController relocation (the fail-open fix)"
# ---------------------------------------------------------------------------
OCC_NEW="$SRC/controller/mobile/OrderCancellationController.java"
OCC_OLD="$SRC/controller/OrderCancellationController.java"
run B1  "OrderCancellationController moved into controller/mobile" file_exists "$OCC_NEW"
run B2  "  ... no longer at the old path"                          bash -c "[ ! -f '$OCC_OLD' ]"
run B3  "  ... package line updated"                               file_contains 'package\s+net\.aim_ai\.wms\.controller\.mobile;' "$OCC_NEW"
run B4  "  ... mapping still /v3/cancellation (no URL change)"      file_contains '@RequestMapping\("/v3/cancellation"\)' "$OCC_NEW"
run B5  "  ... did NOT acquire extends AdminController"             file_not_contains 'extends\s+AdminController' "$OCC_NEW"

# ---------------------------------------------------------------------------
echo
echo "Fix A5 — the golden map: all 11 controllers annotated"
# ---------------------------------------------------------------------------
declare -A MAP=(
  ["mobile/LookupController.java"]="MOBILE_UI_VIEW_INFO"
  ["mobile/PutawayController.java"]="MOBILE_UI_VIEW_PUT_AWAY"
  ["mobile/MoveUnitloadController.java"]="MOBILE_UI_VIEW_TRANSFER"
  ["mobile/MoveStockController.java"]="MOBILE_UI_VIEW_STOCK_TRANSFER"
  ["mobile/PickingController.java"]="MOBILE_UI_VIEW_PICKING"
  ["mobile/PalletizingController.java"]="MOBILE_UI_VIEW_PALLETIZING"
  ["mobile/TruckLoadingController.java"]="MOBILE_UI_VIEW_TRUCK_LOADING"
  ["mobile/CycleCountLosController.java"]="MOBILE_UI_VIEW_CYCLE_COUNT"
  ["mobile/ReplenishController.java"]="MOBILE_UI_VIEW_REPLENISHMENT"
  ["mobile/TransferOrderController.java"]="WEB_UI_VIEW_TRANSFER_ORDER"
  ["mobile/OrderCancellationController.java"]="MOBILE_UI_VIEW_CANCELLATION"
)
i=0
for f in "${!MAP[@]}"; do
  i=$((i+1))
  run "C$i" "$(basename "$f" .java) → ${MAP[$f]}" \
      file_contains "@RequiresFunction\(.*${MAP[$f]}" "$SRC/controller/$f"
done
# Constant references, not string literals — the SBDEV-2863 guard.
# Must assert BOTH that annotations exist AND that none is a literal; the
# not-contains half alone passes vacuously on an unimplemented tree.
run C12 "annotations exist AND none uses a string literal" bash -c "
    grep -rqE '@RequiresFunction\(' '$SRC/controller/mobile' \
      && ! grep -rqE '@RequiresFunction\(\"' '$SRC/controller/mobile'"
# Shared controllers must stay unannotated (§0.B) — with ONE reviewed exception, C13/C13a/C13b below.
#
# ⚠️ C13 was "StockUnitController NOT annotated" until 2026-08-21. It pinned R12's original decision to leave
# POST /v3/stockUnit/transferStock ungated, and the re-review inverted that decision: transferStock is the
# COMMIT action of the gated mobile Move Stock screen, and with the client guard failing open on a slow
# Keycloak init it was reachable by ordinary navigation, not just by deliberate API replay. The row is now
# wrong rather than the code, so it is REPLACED, not deleted — the boundary it protected (a class-level gate
# here would fail closed across ~40 shared endpoints and 403 web screens) still needs pinning.
run C13  "StockUnitController: both reviewed gates carry the ANY-of set (web + mobile)" bash -c "
    perl -0777 -ne 'exit 1 unless /\@RequiresFunction\(\{WmsConstants\.FunctionEnum\.MOBILE_UI_VIEW_STOCK_TRANSFER,\s*WmsConstants\.FunctionEnum\.WEB_UI_VIEW_STOCK_UNIT\}\)[^{}]*?\@PostMapping\(path=\s*.\/transferStock./s' '$SRC/controller/StockUnitController.java' \
      && perl -0777 -ne 'exit 1 unless /\@RequiresFunction\(\{WmsConstants\.FunctionEnum\.MOBILE_UI_VIEW_STOCK_TRANSFER,\s*WmsConstants\.FunctionEnum\.WEB_UI_VIEW_STOCK_UNIT\}\)[^{}]*?\@GetMapping\(path\s*=\s*.\/storageLocationsForStockMovement./s' '$SRC/controller/StockUnitController.java'"
# The class-level ban is what stops the fix widening into the web UI's endpoints. Anchored to the class
# declaration so a method-level annotation elsewhere in the file cannot satisfy it.
run C13a "StockUnitController has NO class-level gate"           bash -c "
    ! perl -0777 -ne 'exit 1 unless /\@RequiresFunction\([^)]*\)\s*(?:\@[A-Za-z]+(?:\([^)]*\))?\s*)*public class StockUnitController/s' '$SRC/controller/StockUnitController.java'"
# Exactly two gates on this shared class: a third would be an unreviewed widening. Counted, not grepped for
# absence, because absence is what the old row asserted and it is no longer the invariant.
run C13b "StockUnitController carries exactly 2 @RequiresFunction" bash -c "
    [ \"\$(grep -cE '^[[:space:]]*@RequiresFunction\(' '$SRC/controller/StockUnitController.java')\" = 2 ]"
run C14 "DashboardController NOT annotated"                      file_not_contains '@RequiresFunction' "$SRC/controller/DashboardController.java"
run C15 "ReplenishOrderController NOT annotated"                 file_not_contains '@RequiresFunction' "$SRC/controller/ReplenishOrderController.java"
run C16 "AdminController NOT annotated (alias trap)"             file_not_contains '@RequiresFunction' "$SRC/controller/AdminController.java"

# ---------------------------------------------------------------------------
echo
echo "Fix C — FunctionEnum + persona seed"
# ---------------------------------------------------------------------------
WC="$SRC/service/WmsConstants.java"
UT="$SRC/controller/rest/UtilRestController.java"
run D1  "MOBILE_UI_VIEW_REPLENISH_REQUEST added to FunctionEnum" file_contains 'MOBILE_UI_VIEW_REPLENISH_REQUEST' "$WC"
run D2  "seed grants MOBILE_UI_VIEW_CANCELLATION"                file_contains 'MOBILE_UI_VIEW_CANCELLATION' "$UT"
run D3  "seed grants WEB_UI_VIEW_TRANSFER_ORDER to >1 role"      file_contains_n 'WEB_UI_VIEW_TRANSFER_ORDER' "$UT" 2
run D4  "seed grants MOBILE_UI_VIEW_REPLENISH_REQUEST"           file_contains 'MOBILE_UI_VIEW_REPLENISH_REQUEST' "$UT"
run D5  "no MOBILE_UI_VIEW_TRANSFER_ORDER invented (D4)"         file_not_contains 'MOBILE_UI_VIEW_TRANSFER_ORDER' "$WC"

# ---------------------------------------------------------------------------
echo
echo "Fix D — Flyway V2.2.18"
# ---------------------------------------------------------------------------
MIG=$(ls "$API/src/main/resources/db/migration/"V2.2.18__*.sql 2>/dev/null | head -1)
if [ -n "${MIG:-}" ]; then
  run E1 "V2.2.18 migration exists"                              file_exists "$MIG"
  run E2 "  ... idempotent via NOT EXISTS (no ON CONFLICT)"      file_contains 'NOT EXISTS' "$MIG"
  # Comments are stripped before asserting ABSENCE. The migration deliberately DOCUMENTS why ON CONFLICT is
  # wrong here (both forms break a different tenant subset), so a bare grep found the anti-pattern inside the
  # warning against it — a false red. Same defect class as S4/S5: a grep row is defeated by any comment that
  # names its subject. Assert over executable SQL only.
  run E3 "  ... does NOT use ON CONFLICT (either form breaks a tenant subset)" bash -c "
      [ -f '$MIG' ] || exit 1
      ! grep -v '^[[:space:]]*--' '$MIG' | grep -qiE 'ON CONFLICT'"
  run E4 "  ... inserts the new function row"                    file_contains 'MOBILE_UI_VIEW_REPLENISH_REQUEST' "$MIG"
  run E5 "  ... back-compat grant off MOBILE_UI_VIEW_REPLENISHMENT" file_contains 'MOBILE_UI_VIEW_REPLENISHMENT' "$MIG"
  run E6 "  ... INSERT-only (no CREATE OR REPLACE ownership trap)" bash -c "
      [ -f '$MIG' ] || exit 1
      ! grep -v '^[[:space:]]*--' '$MIG' | grep -qiE 'CREATE OR REPLACE'"
else
  run E1 "V2.2.18 migration exists"                              file_exists "$API/src/main/resources/db/migration/V2.2.18__MISSING.sql"
  skip E2 "  ... idempotency checks (migration absent)"
  skip E3 "  ... ON CONFLICT check (migration absent)"
  skip E4 "  ... function row check (migration absent)"
  skip E5 "  ... back-compat grant check (migration absent)"
  skip E6 "  ... CREATE OR REPLACE check (migration absent)"
fi
run E7 "no LOCAL migration claims a version above V2.2.18 [pre-passes; see M20 — cannot see other remotes]" \
    bash -c "! ls '$API/src/main/resources/db/migration/'V2.2.19__*.sql '$API/src/main/resources/db/migration/'V2.2.[2-9][0-9]__*.sql 2>/dev/null | grep -q ."
run E8 "audit SQL exists"                                        file_exists "$API/src/main/resources/db/audit-access-invariants.sql"

# ---------------------------------------------------------------------------
echo
echo "Fix E — audit surface"
# ---------------------------------------------------------------------------
run F1 "AccessAuditService exists"                               file_exists "$SRC/service/AccessAuditService.java"
run F2 "  ... uses the BULK Keycloak listing, not per-username"  file_not_contains_code 'existsInKeycloak' "$SRC/service/AccessAuditService.java"
# CORRECTED 2026-08-20. These two rows named AdminController.java and were
# permanently red against a correct implementation. The endpoint is
# `GET /v3/adminAction/accessAudit`, i.e. AdminActionController — declaring it on
# the AdminController BASE would register it under all 43 subclass prefixes
# (~90 alias URLs for one diagnostic). Plan §3.5-E2's "on `AdminController`" was
# the error, not the code. Keyed on the PATH, not the handler method name, per §14.14.
run F3 "accessAudit endpoint added to AdminActionController"      file_contains '"/accessAudit"' "$SRC/controller/AdminActionController.java"
# NOT a bare `file_contains IS_SB_ADMIN` — that would false-green off any other
# gate in the file. Bounded 3-line window above the MAPPING (not the method name).
run F4 "  ... accessAudit specifically is gated on IS_SB_ADMIN" bash -c "
    [ -f '$SRC/controller/AdminActionController.java' ] || exit 1
    grep -B3 '\"/accessAudit\"' '$SRC/controller/AdminActionController.java' | grep -q 'IS_SB_ADMIN'"
# The other half of the same decision: keeping it OFF the base class is what holds
# the alias count at 1. A future 'tidy the admin endpoints' pass would silently
# multiply it by 43, and nothing else in this script would notice.
# ---------------------------------------------------------------------------
# Review fixes 3 and 4 (2026-08-20). Each row pins a defect the independent review found; each was
# negative-tested by reverting the fix and confirming the row goes red.
# ---------------------------------------------------------------------------
run R1 "V2.2.18 guards on `function`, the UNIQUE column"        file_contains 'e\.function = f\.name' "$API/src/main/resources/db/migration/V2.2.18__seed_mobile_workflow_functions.sql"
run R2 "  ... and step 2 dedups its source rows"                file_contains 'SELECT DISTINCT rf\.rolelist_id' "$API/src/main/resources/db/migration/V2.2.18__seed_mobile_workflow_functions.sql"
run R3 "audit SET 4 FILTERS to the locked-out (a real gate)"     file_contains 'workflows_retained = 0' "$API/src/main/resources/db/audit-access-invariants.sql"
run R4 "  ... and keeps the full roster as SET 4b"              file_contains 'SET 4b' "$API/src/main/resources/db/audit-access-invariants.sql"
run R5 "  ... reads the DIRECT user->role grant path too"       file_contains 'mywms_user_mywms_role ur' "$API/src/main/resources/db/audit-access-invariants.sql"
run R6 "  ... and grades against the POST-migration grant set"  file_contains 'projected_held' "$API/src/main/resources/db/audit-access-invariants.sql"

run F5 "  ... and NOT declared on the AdminController base (43-prefix alias trap) [pre-passes]" bash -c "
    [ -f '$SRC/controller/AdminController.java' ] || exit 1
    ! grep -q 'accessAudit' '$SRC/controller/AdminController.java'"

# ---------------------------------------------------------------------------
echo
echo "Fix B — mobile UI route guard"
# ---------------------------------------------------------------------------
run G1 "util/menuCatalog.js exists"                              file_exists "$MOB/util/menuCatalog.js"
run G2 "  ... exports deriveRouteFunctionMap"                    file_contains 'deriveRouteFunctionMap' "$MOB/util/menuCatalog.js"
run G3 "middleware/ directory exists"                            dir_exists "$MOB/middleware"
run G4 "middleware/require-function.js exists"                   file_exists "$MOB/middleware/require-function.js"
run G5 "  ... awaits ensureRolesLoaded before deciding"          file_contains 'ensureRolesLoaded' "$MOB/middleware/require-function.js"
run G6 "middleware registered in nuxt.config.js"                 file_contains "require-function" "$MOB/nuxt.config.js"
run G7 "store/home.js exposes ensureRolesLoaded"                 file_contains 'ensureRolesLoaded' "$MOB/store/home.js"
run G8 "not-authorized.vue no longer uses the missing 'splash'"  file_not_contains 'layout:\s*"splash"' "$MOB/pages/not-authorized.vue"
run G9 "  ... uses a layout that exists on disk"                 bash -c "
    L=\$(grep -oE 'layout:\s*\"[a-z-]+\"' '$MOB/pages/not-authorized.vue' | grep -oE '\"[a-z-]+\"' | tr -d '\"')
    [ -n \"\$L\" ] && [ -f '$MOB/layouts/'\$L'.vue' ]"

# ---------------------------------------------------------------------------
echo
echo "Tests — the controls that make the above provable"
# ---------------------------------------------------------------------------
run H1 "interceptor unit test exists"                            file_exists "$TST/unit/security/FunctionGuardInterceptorUnitTest.java"
run H2 "  ... pins declaring-class over bean-type"               file_contains 'resolvesAnnotationFromDeclaringClassNotBeanType' "$TST/unit/security/FunctionGuardInterceptorUnitTest.java"
run H3 "  ... pins the AdminController alias pass-through"       file_contains 'inheritedAdminControllerAliasIsNotGatedByTheSubclassAnnotation' "$TST/unit/security/FunctionGuardInterceptorUnitTest.java"
run H4 "  ... pins CORS header survival (no reset)"              file_contains 'deniesWithoutCallingResponseReset' "$TST/unit/security/FunctionGuardInterceptorUnitTest.java"
run H5 "  ... distinguishes unprovisioned from no-functions"     file_contains 'deniesWithUnprovisionedReason' "$TST/unit/security/FunctionGuardInterceptorUnitTest.java"
run H6 "  ... asserts exactly one getAllRoles per request"       file_contains 'callsGetAllRolesExactlyOncePerAllowedRequest' "$TST/unit/security/FunctionGuardInterceptorUnitTest.java"
run H7 "  ... clears ThreadLocals in @AfterEach"                 file_contains '@AfterEach' "$TST/unit/security/FunctionGuardInterceptorUnitTest.java"
run H8 "startup-assertion unit test exists"                      file_exists "$TST/unit/security/FunctionGuardStartupAssertionUnitTest.java"
run H9 "ArchUnit golden-map test exists"                         file_exists "$TST/unit/config/FunctionGuardArchTest.java"
run H10 "  ... asserts the golden map by equality"               file_contains 'controllerToFunctionMapMatchesTheGoldenMap' "$TST/unit/config/FunctionGuardArchTest.java"
run H11 "  ... asserts shared controllers stay unannotated"      file_contains 'noSharedControllerCarriesRequiresFunction' "$TST/unit/config/FunctionGuardArchTest.java"
run H12 "  ... asserts AdminController stays unannotated"        file_contains 'adminControllerCarriesNoRequiresFunction' "$TST/unit/config/FunctionGuardArchTest.java"
run H13 "MockMvc guard test exists"                              file_exists "$TST/unit/controller/mobile/FunctionGuardMockMvcUnitTest.java"
run H14 "  ... covers the no-service-in-path endpoint"           file_contains 'truckLoadingOrderListIsForbiddenWithoutTruckLoading' "$TST/unit/controller/mobile/FunctionGuardMockMvcUnitTest.java"
run H15 "  ... covers the self-invoking replenish path"          file_contains 'replenishFulfillMultipleUnitLoadsIsForbidden' "$TST/unit/controller/mobile/FunctionGuardMockMvcUnitTest.java"
run H16 "  ... covers the many-to-many lookup case"              file_contains 'lookupLocationByLocationNameIsAllowedForReplenishOnlyUser' "$TST/unit/controller/mobile/FunctionGuardMockMvcUnitTest.java"
run H17 "BaseControllerUnitTest gains an ADDITIVE guard overload" file_contains 'setupMockMvcWithGuard' "$TST/common/base/BaseControllerUnitTest.java"
run H18 "  ... original setupMockMvc left intact"                file_contains 'protected void setupMockMvc\(Object controller\)' "$TST/common/base/BaseControllerUnitTest.java"
run H19 "mobile-ui middleware spec exists"                       file_exists "$MOB/test/middleware/requireFunction.spec.js"
run H20 "mobile-ui menuCatalog spec exists"                      file_exists "$MOB/test/util/menuCatalog.spec.js"
# --- A2b test surface (added 2026-08-17 with the header re-scope) -----------
run H21 "  ... pins the X-Authz-Denied header on deny"           file_contains 'deniedResponseCarriesTheAuthzDeniedHeaderNamingTheFunction' "$TST/unit/security/FunctionGuardInterceptorUnitTest.java"
SECTEST="$TST/unit/config/SecurityConfigurationTest.java"
run H22 "SecurityConfigurationTest pins the AUTHZ CORS exposure" file_contains 'exposesAuthzDeniedHeader' "$SECTEST"
run H23 "  ... pins the no-duplicate guard for it"               file_contains 'doesNotDuplicateAuthzDeniedHeader' "$SECTEST"
# The pre-existing dedup test asserts containsExactly() on a ONE-header list, so
# it goes red the moment a second header is exposed. It must be EXTENDED to the
# two-header expectation, never relaxed to contains() — relaxing it would let the
# header be dropped again later in silence. (2870 §3.5.1-5 said "this test asserts
# the list exactly"; precisely one of the two does, and it is this one.)
# WIDENED 2026-08-19 (review 2): the plan now prescribes containsExactlyInAnyOrder,
# which preserves exact MEMBERSHIP while dropping an accidental coupling to the order
# of two addExposedHeader calls. Note 'containsExactlyInAnyOrder(' does NOT contain the
# substring 'containsExactly(' - both rows were anchored on the literal and would have
# gone RED on correct code, the same defect as this row's 2026-08-17 error (see 14.5).
# Accept either exact form; reject ONLY the permissive contains(, which tolerates extras.
run H24 "  ... dedup test still asserts an EXACT list (not relaxed to contains) [pre-passes]" bash -c "
    [ -f '$SECTEST' ] || exit 1
    grep -qE 'containsExactly\\(|containsExactlyInAnyOrder\\(' '$SECTEST'"
run H25 "  ... and that exact list now names both headers"       bash -c "
    [ -f '$SECTEST' ] || exit 1
    grep -A2 -E 'containsExactly\\(|containsExactlyInAnyOrder\\(' '$SECTEST' | grep -qE 'X-Authz-Denied|AUTHZ_DENIED_HEADER'"
run H26 "  ... SBDEV-2632 header still asserted (no regression) [pre-passes]" file_contains 'X-Export-Skipped-Cycle-Counts' "$SECTEST"
# Directory-scoped: the plan names test/plugins/axios.spec.js, but this repo's
# plugin specs are per-concern (axios-auth-timing, keycloak-ready, ...), so accept
# the assertion wherever under test/plugins/ the implementer puts it.
run H27 "mobile-ui plugin spec pins the no-retry-on-authz rule"  tree_contains 'doesNotRetryWhenXAuthzDeniedHeaderPresent|X-Authz-Denied' "$MOB/test/plugins"
# COVERAGE GAP found 2026-08-17 by auditing this script's own rows: H27 asserted
# only that a SPEC mentions the header — nothing asserted the shipped code. P10's
# client half (retryCondition must not retry an authorization 403) had no row at
# all, in either the pre-existing G section or the A2b additions. Without H28 the
# script can report 0 fail while the operator is still logged out on every deny.
# Axios lower-cases response header names, so the runtime read is 'x-authz-denied'.
run H28 "mobile-ui plugins/axios.js keys on the authz header"    file_contains 'x-authz-denied|X-Authz-Denied' "$MOB/plugins/axios.js"
# Deliberately NOT a proximity grep tying it to retryCondition: that shape asserts
# "same block" and goes stale under a harmless refactor. That the guard actually
# suppresses the retry-then-logout path is behavioural, and its evidence is M23.

# ---------------------------------------------------------------------------
echo
echo "Inherited preconditions  [inherited] = this plan ASSUMES it, does not build it"
# ---------------------------------------------------------------------------
# ADDED 2026-08-19 - plan 14.7, the structural replacement for R13's prose mitigation.
# A green [inherited] row is NOT this plan's work: it means an assumption still holds.
# A red one means the assumption is an orphan. Three instances of an inherited claim
# carried as fact have already cost this ticket cluster real time (14.7's table).
#
# X1 - instance 2 ("2870 already emits the header") is closed by OWNERSHIP, not by a
# row: 3.1-A2b builds the constant and the emitter here. Recorded so the closure is
# deliberate rather than forgotten. The rows that grade it are A26-A31 / H21-H28.
skip X1 "[inherited] header emitter owned here, not assumed (see 3.1-A2b)"
#
# X2 - instance 3 (14.6): M23 needs a subject holding MOBILE_UI_LOG_IN and ZERO
# MOBILE_UI_VIEW_*. Measured 2026-08-18: no such live user exists on either reachable
# tenant. RESOLVED 2026-08-19 (14.9): no new account needed - 'sbtest' (mywms_user id
# 19800000, group 'test group' -> role 'test role', role id 30262745) becomes a literal
# subject by adding MOBILE_UI_LOG_IN (function id 51764) to that role. It keeps
# WEB_UI_LOG_IN, which is not a MOBILE_UI_VIEW_* so the deny case is intact. This row
# stays RED until the evidence file below is written - the INSERT alone does not flip it,
# deliberately: the row grades recorded proof, not an intention. This shell cannot reach the DB, so the row grades the RECORDED result of the
# query - drop the SELECT output at the path below when the account is created. This is
# the row that would have found 14.6 the day 3.5 was written rather than the day the
# account was needed.
# Anchored to THIS script, not PROJECT_ROOT: PROJECT_ROOT is repointed at a symlink
# shadow root when grading a worktree, and sbdocs does not exist under it.
ACCT_EVIDENCE="${ACCT_EVIDENCE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/evidence/SBDEV-2968-m23-test-account.txt}"
if [ -f "$ACCT_EVIDENCE" ]; then
  run X2 "[inherited] an M23 test subject exists (MOBILE_UI_LOG_IN, 0 view fns)" \
      file_contains 'MOBILE_UI_LOG_IN' "$ACCT_EVIDENCE"
else
  run X2 "[inherited] an M23 test subject exists - RED until 14.6's account is created" false
fi
#
# X3 - the consuming-plan backstop, listed here for completeness and graded in
# SBDEV-2967's row set: Fix E must resolve Authority.AUTHZ_DENIED_HEADER by symbol, so
# a fourth re-home breaks 2967's BUILD instead of silently logging operators out.
skip X3 "[inherited] 2967 resolves AUTHZ_DENIED_HEADER by symbol (graded in 2967)"

# ---------------------------------------------------------------------------
echo
# ---------------------------------------------------------------------------
echo
echo "Fix R16 - the one gateable SDR hole, closed by REMOVAL not by a guard (AC-32, 14.12.b)"
# ---------------------------------------------------------------------------
# Decided 2026-08-20: options D + C. Un-export ONLY findByAssignedlocationId and serve
# the upperbound scalar from a @RequiresFunction-annotated ReplenishController read.
# The four SHARED SDR searches take option A (stated residual, R12) - deliberately NOT
# asserted here, because gating them would 403 a web screen.
FLAR="$API/src/main/java/net/aim_ai/wms/repo/jpa/FixLocationAssignmentRepository.java"
# Windowed match in the house idiom (grep -B/-A + grep), not an invented helper:
# a bare file_contains would pass on ANY exported=false in the file, of which there
# may legitimately be others later.
run S1 "findByAssignedlocationId is NOT exported over HAL" bash -c "
    [ -f '$FLAR' ] || exit 1
    grep -B2 -A2 'findByAssignedlocationId' '$FLAR' | grep -qE 'exported\s*=\s*false'"
run S2 "  ... and its 8 sibling searches are STILL exported (no blanket un-export) [pre-passes]" \
    bash -c "[ -f '$FLAR' ] && [ \$(grep -c 'exported\s*=\s*false' '$FLAR') -le 2 ]"
# Anchored on the MAPPING, not on the word: the original row matched 'upperbound' anywhere in the file, so a
# comment mentioning it satisfied the row. Same defect class as S5, which a comment also falsified.
run S3 "ReplenishController serves the upperbound scalar" \
    file_contains '@GetMapping\(path = "/fixedLocationUpperBound' "$API/src/main/java/net/aim_ai/wms/controller/mobile/ReplenishController.java"
# 🔴 REWRITTEN: the proximity form was a FALSE GREEN. The endpoint inherits the class-level annotation
# (A5 lists only the two overrides that CHANGE the function), so there is no method-level @RequiresFunction to
# find — and the row passed anyway, because the explanatory comment above the method contains the literal
# string "@RequiresFunction" while saying the opposite. Assert the class-level gate structurally instead:
# the annotation must sit on the line immediately preceding the class declaration, which no comment can fake.
run S4 "  ... and it is gated by ReplenishController's class-level annotation (inherited)" bash -c "
    RC='$API/src/main/java/net/aim_ai/wms/controller/mobile/ReplenishController.java'
    [ -f \"\$RC\" ] || exit 1
    grep -B1 '^public class ReplenishController' \"\$RC\" | grep -q '@RequiresFunction(WmsConstants.FunctionEnum.MOBILE_UI_VIEW_REPLENISHMENT)'"
run S5 "mobile caller no longer hits the SDR search path" \
    file_not_contains 'fixLocationAssignment/search' "$MOB/components/replenish/shared/OrderHeaderBlock.vue"
run S6 "  ... and the 3-shape defensive parsing is deleted (resp.content fallback gone)" \
    file_not_contains 'Array\.isArray\(resp\.content\)' "$MOB/components/replenish/shared/OrderHeaderBlock.vue"


# ---------------------------------------------------------------------------
echo
echo "Fix R15 - the denial must RENDER, not just be returned (step 15)"
# ---------------------------------------------------------------------------
# The scan* endpoints answer failure with HTTP 200 + {"errors":[...]}; the interceptor
# answers 403 + ProblemDetail. Two contracts on the same screens (14.11.b). A spec that
# only proves the 403 is EMITTED proves nothing about whether the operator sees it.
# 🔴 TIGHTENED: the original matched 'ProblemDetail|problemDetail|403' anywhere under test/, so an unrelated
# spec that merely mentioned a 403 status satisfied it — and one did (the P10 retry spec), turning this row
# green while nothing asserted rendering at all. Anchor on the feature's own symbol instead.
run T1 "a mobile spec asserts a 403 ProblemDetail renders the typed message" \
    tree_contains 'authzDenialMessage' "$MOB/test"
# Asserts the PRODUCTION handler discriminates, rather than asserting the absence of a pattern in tests —
# an absence row here was vacuous, and could never distinguish "keyed correctly" from "not implemented".
run T2 "  ... and the handler keys on the 403 status AND the ProblemDetail reason" \
    file_contains 'status === 403 && body\.reason' "$MOB/plugins/axios.js"


echo "Anti-regression"
# ---------------------------------------------------------------------------
run I1 "no @PreAuthorize used for a function check on mobile"     tree_not_contains '@PreAuthorize.*MOBILE_UI_VIEW' "$SRC/controller/mobile"
run I2 "no per-endpoint service-layer guard sprawl"               bash -c "
    c=\$(grep -rE 'doesUserHaveAnyAccess|checkAnyAccess' '$SRC/service/mobile' 2>/dev/null | wc -l); [ \"\$c\" -eq 0 ]"
run I3 "the 5 shared endpoints' controllers still exist"          bash -c "
    [ -f '$SRC/controller/StockUnitController.java' ] && [ -f '$SRC/controller/DashboardController.java' ] && [ -f '$SRC/controller/ReplenishOrderController.java' ]"

# ---------------------------------------------------------------------------
echo
printf "Result: %d pass, %d fail, %d skip\n" "$PASS" "$FAIL" "$SKIP"
echo
[ "$FAIL" -eq 0 ]
