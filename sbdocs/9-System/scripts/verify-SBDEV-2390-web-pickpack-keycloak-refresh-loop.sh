#!/usr/bin/env bash
# verify-SBDEV-2390-web-pickpack-keycloak-refresh-loop.sh
# Machine-checkable acceptance for the WEB UI Keycloak refresh/redirect-loop fix (SBDEV-2390).
#
#   $ PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-web-ui \
#       bash sbdocs/9-System/scripts/verify-SBDEV-2390-web-pickpack-keycloak-refresh-loop.sh
#
# Exit 0 only when every check passes. Paste the final "Result:" line in the task report.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-web-ui}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi
}
skip() { printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

file_contains()      { grep -qE "$1" "$2"; }
file_not_contains()  { ! grep -qE "$1" "$2"; }
dir_contains()       { grep -rqE "$1" "$2"; }   # pattern, dir

KC=plugins/keycloak.client.js
IDX=pages/index.vue
UT=pages/unknown-tenant.vue
PLUGINS=plugins

# --- Fix A: restore check-sso -------------------------------------------------
# Anchor to line start so the currently-COMMENTED `// onLoad: 'check-sso'` does NOT satisfy it.
check_A_checksso_on()   { file_contains "^[[:space:]]*onLoad:[[:space:]]*'check-sso'" "$KC"; }
check_A_loginreq_gone() { file_not_contains "^[[:space:]]*onLoad:[[:space:]]*'login-required'" "$KC"; }

# --- Fix B: sessionStorage loop-breaker --------------------------------------
# Helper may live in $KC or a separate plugins/kc-redirect-guard.js — search plugins/.
check_B_max_const()     { dir_contains "MAX_KC_REDIRECTS\s*=\s*2" "$PLUGINS"; }
check_B_counter_key()   { dir_contains "sessionStorage" "$PLUGINS"; }
check_B_guardedlogin()  { dir_contains "function guardedLogin|guardedLogin\s*=" "$PLUGINS"; }
check_B_reset_fn()      { dir_contains "resetRedirectCount" "$PLUGINS"; }
check_B_bump_fn()       { dir_contains "bumpRedirectCount" "$PLUGINS"; }
# Loop-breaker lands on the clear-error page. Require ?reason=auth so this does NOT match the
# pre-existing no-config redirect `location.replace('/unknown-tenant')` (which has no query).
check_B_breaker_redir() { dir_contains "location\.replace\('/unknown-tenant\?reason=auth" "$PLUGINS"; }
# guardedLogin is actually wired at the call-site.
check_B_guard_wired()   { file_contains "guardedLogin\(" "$KC"; }
# No un-guarded keycloakInstance.login() left (site 2/3 must route through guardedLogin).
check_B_no_raw_login()  { file_not_contains "keycloakInstance\.login\(\)" "$KC"; }

# --- Fix C: tokenParsedfg typo ------------------------------------------------
check_C_typo_gone()     { file_not_contains "tokenParsedfg" "$IDX"; }
check_C_correct()       { file_contains "event\.detail\.tokenParsed\b" "$IDX"; }

# --- Fix E: clear-error coverage ---------------------------------------------
check_E_error_guard()   { file_contains "route\.path === '/error'" "$KC"; }
check_E_reason_copy()   { file_contains "reason" "$UT"; }

echo
echo "verify-SBDEV-2390-web — running acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

run A1  "Fix A — onLoad:'check-sso' restored"           check_A_checksso_on
run A2  "Fix A — onLoad:'login-required' gone"          check_A_loginreq_gone
echo
run B1  "Fix B — MAX_KC_REDIRECTS = 2"                  check_B_max_const
run B2  "Fix B — sessionStorage counter present"        check_B_counter_key
run B3  "Fix B — guardedLogin helper present"           check_B_guardedlogin
run B4  "Fix B — resetRedirectCount present"            check_B_reset_fn
run B5  "Fix B — bumpRedirectCount present"             check_B_bump_fn
run B6  "Fix B — breaker redirects to /unknown-tenant?reason=auth"  check_B_breaker_redir
run B7  "Fix B — guardedLogin wired at call-site"       check_B_guard_wired
run B8  "Fix B — no un-guarded keycloakInstance.login()" check_B_no_raw_login
echo
run C1  "Fix C — tokenParsedfg typo gone"               check_C_typo_gone
run C2  "Fix C — event.detail.tokenParsed correct"      check_C_correct
echo
run E1  "Fix E — '/error' in keycloak skip-guard"       check_E_error_guard
run E2  "Fix E — unknown-tenant.vue handles reason"     check_E_reason_copy
echo
# Behavior check (uncomment once the spec exists):
# run BT "Fix B — loop-breaker unit test passes" bash -c "yarn test --testPathPattern=keycloak-redirect-guard 2>&1 | grep -qE 'PASS|Tests:.*failed, 0'"
skip BT "Fix B — loop-breaker unit test passes" "run 'yarn test --testPathPattern=keycloak-redirect-guard' after implementing the spec"

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
