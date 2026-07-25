#!/usr/bin/env bash
# verify-SBDEV-2390-mobile-pickpack-keycloak-refresh-loop.sh
# Machine-checkable acceptance for the MOBILE UI Keycloak refresh/redirect-loop fix (SBDEV-2390).
#
#   $ PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-mobile-ui \
#       bash sbdocs/9-System/scripts/verify-SBDEV-2390-mobile-pickpack-keycloak-refresh-loop.sh
#
# Mobile has NO Jest harness — these are code-shape checks; behavior is validated by manual QA (plan §8).
# Exit 0 only when every check passes.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-mobile-ui}"
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
dir_contains()       { grep -rqE "$1" "$2"; }

KC=plugins/keycloak.client.js
UT=pages/unknown-tenant.vue
PLUGINS=plugins

# --- Fix A: restore check-sso + /mobile/ silent uri --------------------------
# Anchor to line start so a commented `// onLoad: 'check-sso'` does NOT satisfy it.
check_A_checksso_on()   { file_contains "^[[:space:]]*onLoad:[[:space:]]*'check-sso'" "$KC"; }
check_A_loginreq_gone() { file_not_contains "^[[:space:]]*onLoad:[[:space:]]*'login-required'" "$KC"; }
# silent uri must be uncommented (line does not start with //).
check_A_silent_uri()    { file_contains "^[[:space:]]*silentCheckSsoRedirectUri.*/mobile/silent-check-sso\.html" "$KC"; }

# --- Fix B: sessionStorage loop-breaker --------------------------------------
check_B_max_const()     { dir_contains "MAX_KC_REDIRECTS\s*=\s*2" "$PLUGINS"; }
check_B_counter_key()   { dir_contains "sessionStorage" "$PLUGINS"; }
check_B_guardedlogin()  { dir_contains "function guardedLogin|guardedLogin\s*=" "$PLUGINS"; }
check_B_reset_fn()      { dir_contains "resetRedirectCount" "$PLUGINS"; }
check_B_bump_fn()       { dir_contains "bumpRedirectCount" "$PLUGINS"; }
check_B_guard_wired()   { file_contains "guardedLogin\(" "$KC"; }
# Breaker + Fix D redirect land on the /mobile/ clear-error page (open-ended prefix).
check_B_breaker_redir() { file_contains "location\.replace\('/mobile/unknown-tenant" "$KC"; }

# --- Fix D: dead-code catch replaced by guarded clear-error ------------------
# Line-based: the dead `state.keycloakInstance.login()` call must be gone (grep can't match the
# multi-line `if (state.keycloakInstance) {` construct, so assert the inner call line is removed).
check_D_deadcode_gone() { file_not_contains "state\.keycloakInstance\.login\(\)" "$KC"; }
# Catch path counts the attempt (breadcrumb) before redirecting.
check_D_catch_bump()    { file_contains "bumpRedirectCount" "$KC"; }
# No un-guarded raw login() left on site 2 (must route through guardedLogin).
check_D_no_raw_login()  { file_not_contains "keycloakInstance\.login\(\)" "$KC"; }
# Loop-safety: the fix must NOT introduce a reload on the catch path.
check_D_no_reload()     { file_not_contains "window\.location\.reload\(" "$KC"; }

# --- Fix E: clear-error copy --------------------------------------------------
check_E_reason_copy()   { file_contains "reason" "$UT"; }

echo
echo "verify-SBDEV-2390-mobile — running acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

run A1  "Fix A — onLoad:'check-sso' restored"            check_A_checksso_on
run A2  "Fix A — onLoad:'login-required' gone"           check_A_loginreq_gone
run A3  "Fix A — /mobile/ silentCheckSsoRedirectUri"     check_A_silent_uri
echo
run B1  "Fix B — MAX_KC_REDIRECTS = 2"                   check_B_max_const
run B2  "Fix B — sessionStorage counter present"         check_B_counter_key
run B3  "Fix B — guardedLogin helper present"            check_B_guardedlogin
run B4  "Fix B — resetRedirectCount present"             check_B_reset_fn
run B5  "Fix B — bumpRedirectCount present"              check_B_bump_fn
run B6  "Fix B — guardedLogin wired at call-site"        check_B_guard_wired
run B7  "Fix B — redirects to /mobile/unknown-tenant"    check_B_breaker_redir
echo
run D1  "Fix D — dead-code null-guard login() gone"      check_D_deadcode_gone
run D2  "Fix D — catch increments counter (breadcrumb)"  check_D_catch_bump
run D3  "Fix D — no un-guarded keycloakInstance.login()" check_D_no_raw_login
run D4  "Fix D — no window.location.reload() on catch"   check_D_no_reload
echo
run E1  "Fix E — unknown-tenant.vue handles reason"      check_E_reason_copy
echo
skip MT "Behavior — manual QA (§8): refresh + desktop/mobile bounce + tenant-fail" "mobile has no test harness; run the §8 manual table on staging"

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
