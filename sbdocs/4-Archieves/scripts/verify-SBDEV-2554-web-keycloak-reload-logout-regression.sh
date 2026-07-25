#!/usr/bin/env bash
# verify-SBDEV-2554-web-keycloak-reload-logout-regression.sh
# Machine-checkable acceptance for SBDEV-2554 (wms2-web-ui).
#
#   PROJECT_ROOT=/path/to/owl/v2/wms2-web-ui \
#     bash sbdocs/9-System/scripts/verify-SBDEV-2554-web-keycloak-reload-logout-regression.sh
#
# Exit 0 iff every check passes. Paste the final "Result:" line in the
# end-of-task report. Code-shape greps prove the call exists; the Jest specs
# (run separately) prove it works.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-web-ui}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0

run() {
  local id=$1 desc=$2; shift 2
  if "$@" >/dev/null 2>&1; then printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
  else printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi
}
file_contains()     { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }

KC=plugins/keycloak.client.js
AX=plugins/axios.js

# --- Fix A: ready promise on the façade -----------------------------------
check_A_ready_getter()  { file_contains 'get\s+ready\s*\(\s*\)\s*\{'         "$KC"; }
check_A_authReady()     { file_contains 'authReady'                          "$KC"; }
check_A_settle()        { file_contains 'settleReady'                        "$KC"; }

# --- Fix B: onRequest awaits ready, uses live token ------------------------
check_B_helper()        { file_contains 'function\s+awaitAuthReady|awaitAuthReady\s*='   "$AX"; }
check_B_onrequest_async(){ file_contains 'onRequest\(\s*async'               "$AX"; }
check_B_await()         { file_contains 'await\s+awaitAuthReady'             "$AX"; }

# --- Fix C: retryCondition no longer logs out on !authenticated ------------
# NOTE: a grep cannot robustly prove "no logout in the !authenticated branch"
# (a reformat defeats any comment/string match). These are ADVISORY shape checks;
# the AUTHORITATIVE gate is the Jest spec asserting logout is NOT called during
# the init window. POSITIVE marker of the new behavior instead:
check_C_async_retry()   { file_contains 'async\s+retryCondition'            "$AX"; }
check_C_defer_marker()  { file_contains 'deferring to Keycloak login'       "$AX"; }
check_C_no_promise_wrap(){ file_not_contains 'return new Promise\(\(resolve, reject\)' "$AX"; }

# --- Fix D: terminal logout guarded on authenticated -----------------------
check_D_guarded()       { file_contains 'app\.\$kc\.authenticated\s*&&\s*app\.\$kc\.logout' "$AX"; }

# --- Regression guards: SBDEV-2390 loop fix intact -------------------------
check_R_checksso()      { file_contains "onLoad:\s*'check-sso'"              "$KC"; }
check_R_no_loginreq()   { file_not_contains "onLoad:\s*'login-required'"     "$KC"; }
check_R_guard_kept()    { file_contains 'guardedLogin'                       "$KC"; }

echo
echo "verify-SBDEV-2554-web — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo
run A1  "Fix A — get ready() on façade"                 check_A_ready_getter
run A2  "Fix A — authReady promise present"             check_A_authReady
run A3  "Fix A — settleReady() present"                 check_A_settle
echo
run B1  "Fix B — awaitAuthReady helper defined"         check_B_helper
run B2  "Fix B — onRequest is async"                    check_B_onrequest_async
run B3  "Fix B — onRequest awaits ready"                check_B_await
echo
run C1  "Fix C — retryCondition is async"               check_C_async_retry
run C2  "Fix C — !authenticated defers to login (marker)" check_C_defer_marker
run C3  "Fix C — old new Promise wrapper removed"        check_C_no_promise_wrap
echo
run D1  "Fix D — terminal logout guarded on authenticated" check_D_guarded
echo
run R1  "Regression — onLoad check-sso kept"            check_R_checksso
run R2  "Regression — login-required NOT reintroduced"  check_R_no_loginreq
run R3  "Regression — guardedLogin loop-breaker kept"   check_R_guard_kept
echo
echo "  NOTE: greps are advisory. Authoritative gate = Jest axios-auth-timing.spec.js"
echo "        (asserts app.\$kc.logout NOT called on 401 while init pending)."
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
