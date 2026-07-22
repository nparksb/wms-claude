#!/usr/bin/env bash
# verify-SBDEV-2391-wms-refresh-tenant-not-recognized.sh
# Machine-checkable acceptance for the WEB UI tenant-discovery transient-vs-permanent fix (SBDEV-2391).
#
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2391-wms-refresh-tenant-not-recognized.sh
#   $ PROJECT_ROOT=/path/to/wms2-web-ui bash sbdocs/9-System/scripts/verify-SBDEV-2391-...sh
#
# Exit 0 only when every check passes. Paste the final "Result:" line in the task report.
#
# NOTE: grep proves code SHAPE (present/absent) only. Behavior is proven by the named Jest
# tests (see plan §6/§8). Both are required; neither alone is sufficient.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/Users/np1076/dev/spk/owl/v2/wms2-web-ui}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi
}
skip() { printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

file_contains()     { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { ! grep -qE "$1" "$2" 2>/dev/null; }
file_exists()       { test -f "$1"; }

INIT=plugins/initTenantAuth.client.js
KC=plugins/keycloak.client.js
FETCH=plugins/tenant-auth-fetch.js
UT=pages/unknown-tenant.vue

# =============================================================================
# Fix B (prerequisite) — extracted Nuxt-free retry/classification helper
# =============================================================================
check_B_helper_exists()   { file_exists "$FETCH"; }
# (d) POSITIVE — response.ok / res.status===404 classification present.
check_B_ok_handling()     { file_contains "response\.ok|res(ponse)?\.status" "$FETCH"; }
check_B_404_handling()    { file_contains "status\s*===\s*404|=== 404|status === 404" "$FETCH"; }
# (e) POSITIVE — MAX_ATTEMPTS + AbortController present.
check_B_max_attempts()    { file_contains "MAX_ATTEMPTS\s*=\s*3" "$FETCH"; }
check_B_timeout_const()   { file_contains "TIMEOUT_MS\s*=\s*5000" "$FETCH"; }
check_B_backoff_const()   { file_contains "BACKOFF_MS\s*=\s*300" "$FETCH"; }
check_B_abortcontroller() { file_contains "AbortController" "$FETCH"; }

# =============================================================================
# Fix A — dead status===500 removed from initTenantAuth
# =============================================================================
# (a) NEGATIVE — the dead status===500 branch is gone.
check_A_dead500_gone()    { file_not_contains "tenantConfig\.status\s*===\s*500|status === 500" "$INIT"; }

# =============================================================================
# Fix A/E — no setItem('tenantKeycloakConfig', null) sites remain
# =============================================================================
# (b) NEGATIVE — zero setItem('tenantKeycloakConfig', null) remain (was 58/87/117).
check_E_no_null_setitem() { file_not_contains "setItem\('tenantKeycloakConfig',\s*null\)" "$INIT"; }

# =============================================================================
# Fix D — !clientInfo branch short-circuits with a return before the fetch
# =============================================================================
# (c) POSITIVE — a return exists inside the !clientInfo block, before the fetch.
# Anchored so the return sits between the `if (!clientInfo)` guard and the fetch call.
check_D_short_circuit()   {
    perl -0777 -ne 'exit 0 if /if\s*\(\s*!\s*clientInfo\s*\).*?\breturn\b.*?fetch\(/s; exit 1' "$INIT" 2>/dev/null
}

# =============================================================================
# Fix E — 'null'-as-missing reader guard in keycloak.client.js
# =============================================================================
# (g) POSITIVE — getKeycloakConfig treats the string 'null'/'undefined' as missing.
# Post-refactor: the guard now delegates to the shared isMissingConfig() from
# tenant-auth-fetch.js (single source of truth) instead of a hand-inlined string check;
# accept either the shared-helper call or the legacy inline literal.
check_E_null_guard()      { file_contains "isMissingConfig\(storedConfig\)|storedConfig === 'null'|=== 'null'|'null'\s*\|\||=== \"null\"" "$KC"; }

# =============================================================================
# Fix F — single-writer redirect discipline (sessionStorage arbitration)
# =============================================================================
# Post-refactor: the flag key is now the shared DISCOVERY_REDIRECT_KEY constant from
# tenant-auth-fetch.js (single source of truth). Accept the constant OR the legacy literal.
check_F_flag_key()        { file_contains "DISCOVERY_REDIRECT_KEY|tenantDiscoveryRedirect" "$INIT"; }
check_F_sessionstorage()  { file_contains "sessionStorage" "$INIT"; }
# initTenantAuth is the writer of ?reason=unavailable.
check_F_reason_unavail()  { file_contains "reason=unavailable|classifyRedirect" "$INIT"; }
# keycloak.client.js bare redirect is now reason-aware (checks the flag before its bare redirect).
# Anchor on the sessionStorage READ of the flag, not any reference, so the check fails if the
# skip logic is deleted while the import lingers (LOW nit from SBDEV-2391 delta re-review).
check_F_kc_flag_aware()   { file_contains "getItem\((DISCOVERY_REDIRECT_KEY|'tenantDiscoveryRedirect')\)" "$KC"; }
# (AC8) POSITIVE — initTenantAuth unconditionally clears the flag at the start of every run.
check_F_init_clear()      { file_contains "removeItem\((DISCOVERY_REDIRECT_KEY|'tenantDiscoveryRedirect')\)" "$INIT"; }
# (AC8) POSITIVE — unknown-tenant.vue mounted() unconditionally clears the flag on page mount.
check_F_ut_clear()        { file_contains "removeItem\((DISCOVERY_REDIRECT_KEY|'tenantDiscoveryRedirect')\)" "$UT"; }

# =============================================================================
# Fix C — recoverable unknown-tenant page (reason=unavailable + Retry reload)
# =============================================================================
# (f) POSITIVE — reason='unavailable' / isUnavailable present in unknown-tenant.vue.
check_C_isunavailable()   { file_contains "isUnavailable|reason === 'unavailable'|'unavailable'" "$UT"; }
# Retry re-runs cold boot on the ORIGINAL url via reload(), NOT replace('/') (M1).
check_C_retry_reload()    { file_contains "location\.reload\(\)" "$UT"; }
check_C_no_replace_root() { file_not_contains "location\.replace\('/'\)" "$UT"; }

# =============================================================================
# (h) NON-REGRESSION — SBDEV-2390 must remain intact in keycloak.client.js
# =============================================================================
check_NR_guardedlogin()   { file_contains "guardedLogin" "$KC"; }
check_NR_resetcount()     { file_contains "resetRedirectCount" "$KC"; }
check_NR_reason_auth()    { file_contains "reason=auth" "$KC"; }
check_NR_checksso()       { file_contains "^[[:space:]]*onLoad:[[:space:]]*'check-sso'" "$KC"; }
# POSITIVE — unknown-tenant.vue still preserves the SBDEV-2390 auth-error copy state.
check_NR_ut_auth_state()  { file_contains "reason === 'auth'|isAuthError" "$UT"; }

echo
echo "verify-SBDEV-2391-wms — running acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# --- Fix B (prerequisite helper) ---------------------------------------------
run B1  "Fix B — plugins/tenant-auth-fetch.js exists"        check_B_helper_exists
run B2  "Fix B — response.ok / res.status handling present"  check_B_ok_handling
run B3  "Fix B — 404 classification present"                 check_B_404_handling
run B4  "Fix B — MAX_ATTEMPTS = 3"                           check_B_max_attempts
run B5  "Fix B — TIMEOUT_MS = 5000"                          check_B_timeout_const
run B6  "Fix B — BACKOFF_MS = 300"                           check_B_backoff_const
run B7  "Fix B — AbortController present (timeout bound)"    check_B_abortcontroller
echo
# --- Fix A (dead 500 removed) ------------------------------------------------
run A1  "Fix A — dead status===500 branch gone"              check_A_dead500_gone
echo
# --- Fix A/E (null setItem gone) ---------------------------------------------
run E1  "Fix E — no setItem('tenantKeycloakConfig', null)"   check_E_no_null_setitem
echo
# --- Fix D (short-circuit) ---------------------------------------------------
run D1  "Fix D — !clientInfo returns before fetch"           check_D_short_circuit
echo
# --- Fix E (reader guard) ----------------------------------------------------
run E2  "Fix E — 'null'-as-missing guard in getKeycloakConfig" check_E_null_guard
echo
# --- Fix F (single-writer arbitration) ---------------------------------------
run F1  "Fix F — tenantDiscoveryRedirect flag in initTenantAuth" check_F_flag_key
run F2  "Fix F — sessionStorage used in initTenantAuth"       check_F_sessionstorage
run F3  "Fix F — initTenantAuth writes ?reason=unavailable"   check_F_reason_unavail
run F4  "Fix F — keycloak.client.js bare redirect is flag-aware" check_F_kc_flag_aware
run F5  "Fix F — initTenantAuth clears flag at start of run (AC8)" check_F_init_clear
run F6  "Fix F — unknown-tenant.vue mounted() clears flag (AC8)" check_F_ut_clear
echo
# --- Fix C (recoverable page) ------------------------------------------------
run C1  "Fix C — unknown-tenant handles reason=unavailable"  check_C_isunavailable
run C2  "Fix C — Retry uses location.reload() (original url)" check_C_retry_reload
run C3  "Fix C — Retry does NOT use replace('/')"            check_C_no_replace_root
echo
# --- (h) SBDEV-2390 non-regression -------------------------------------------
run NR1 "NR — SBDEV-2390 guardedLogin still present"         check_NR_guardedlogin
run NR2 "NR — SBDEV-2390 resetRedirectCount still present"   check_NR_resetcount
run NR3 "NR — SBDEV-2390 ?reason=auth loop-breaker intact"   check_NR_reason_auth
run NR4 "NR — SBDEV-2390 onLoad:'check-sso' intact"          check_NR_checksso
run NR5 "NR — unknown-tenant.vue preserves SBDEV-2390 auth-error state (reason=auth/isAuthError)" check_NR_ut_auth_state
echo

# --- Behavior checks (Jest) — proven behavior, not just shape -----------------
# Uncomment once the specs exist. Behavior AC2/AC3/AC7/C1/C2 are covered here.
# run BT1 "Behavior — tenant-auth-fetch retry/classify tests pass" \
#     bash -c "yarn test --testPathPattern=tenant-auth-fetch 2>&1 | grep -qE 'PASS|Tests:.*failed, 0'"
# run BT2 "Behavior — keycloak/tenant plugin tests pass" \
#     bash -c "yarn test --testPathPattern=keycloak 2>&1 | grep -qE 'PASS|Tests:.*failed, 0'"
skip BT1 "Behavior — tenant-auth-fetch Jest tests" "run 'yarn test --testPathPattern=tenant-auth-fetch' after implementing the spec"
skip BT2 "Behavior — keycloak/tenant Jest tests"   "run 'yarn test --testPathPattern=keycloak' after implementing the spec"

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
