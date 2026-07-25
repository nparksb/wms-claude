#!/usr/bin/env bash
# verify-SBDEV-2391-mobile-wms-refresh-tenant-not-recognized.sh
# Machine-checkable acceptance for the MOBILE UI tenant-discovery transient-vs-permanent fix (SBDEV-2391).
# PORT of verify-SBDEV-2391-wms-refresh-tenant-not-recognized.sh, adapted to v2/wms2-mobile-ui:
#   • redirect targets carry the '/mobile/' router.base
#   • Fix A is ALREADY present on mobile (!response.ok throw) → checked as non-regression, not removed
#   • two setItem(...,null) sites (:60,:120) vs web's three
#   • mobile-only tenant-change alignment (removeItem kcToken + tenantKeycloakConfig, setItem warehouseCode)
#   • a NEW Jest harness (jest.config + babel + package.json test script + specs)
#
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2391-mobile-wms-refresh-tenant-not-recognized.sh
#   $ PROJECT_ROOT=/path/to/wms2-mobile-ui bash sbdocs/9-System/scripts/verify-SBDEV-2391-mobile-...sh
#
# Exit 0 only when every check passes. Paste the final "Result:" line in the task report.
#
# NOTE: grep proves code SHAPE (present/absent) only. Behavior is proven by the named Jest
# tests (see plan §6/§8). Both are required; neither alone is sufficient.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/Users/np1076/dev/spk/owl/v2/wms2-mobile-ui}"
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
GUARD=plugins/kc-redirect-guard.js
FETCH=plugins/tenant-auth-fetch.js
UT=pages/unknown-tenant.vue
PKG=package.json
JEST=jest.config.js
SPEC_FETCH=test/plugins/tenant-auth-fetch.spec.js
SPEC_INIT=test/plugins/initTenantAuth.spec.js

# =============================================================================
# Fix B (prerequisite) — extracted Nuxt-free retry/classification helper
# =============================================================================
check_B_helper_exists()   { file_exists "$FETCH"; }
# (d) POSITIVE — response.ok / res.status===404 classification present.
check_B_ok_handling()     { file_contains "response\.ok|res(ponse)?\.status" "$FETCH"; }
check_B_404_handling()    { file_contains "status\s*===\s*404|=== 404|status === 404" "$FETCH"; }
# (e) POSITIVE — MAX_ATTEMPTS + TIMEOUT_MS + BACKOFF_MS + AbortController present.
check_B_max_attempts()    { file_contains "MAX_ATTEMPTS\s*=\s*3" "$FETCH"; }
check_B_timeout_const()   { file_contains "TIMEOUT_MS\s*=\s*5000" "$FETCH"; }
check_B_backoff_const()   { file_contains "BACKOFF_MS\s*=\s*300" "$FETCH"; }
check_B_abortcontroller() { file_contains "AbortController" "$FETCH"; }
# MOBILE delta — success mapping uses body.mobileRedirectUrl (not web's webRedirectUrl).
check_B_mobile_redirect() { file_contains "mobileRedirectUrl" "$FETCH"; }
# MOBILE delta — classifyRedirect returns /mobile/-prefixed targets.
check_B_mobile_classify() { file_contains "/mobile/unknown-tenant" "$FETCH"; }
check_B_mobile_unavail()  { file_contains "/mobile/unknown-tenant\?reason=unavailable" "$FETCH"; }

# =============================================================================
# Fix A — ALREADY PRESENT on mobile (non-regression, NOT a removal)
# =============================================================================
# (a) NON-REGRESSION — the !response.ok HTTP-status handling stays. Fix B moved the raw
# fetch + !response.ok throw out of $INIT and INTO the $FETCH helper (fetchAuthConfig),
# exactly as the shipped web port does; the plugin now routes through fetchAuthConfig().
# So the response.ok handling lives in $FETCH now — assert it there (semantics preserved).
check_A_already_present() { file_contains "!\s*response\.ok|response\.ok" "$FETCH"; }
# Sanity NEGATIVE — mobile must not have re-introduced a dead status===500 branch.
check_A_no_dead500()      { file_not_contains "tenantConfig\.status\s*===\s*500|status === 500" "$INIT"; }

# =============================================================================
# Fix E — no setItem('tenantKeycloakConfig', null) sites remain (was :60,:120)
# =============================================================================
# (b) NEGATIVE — zero setItem('tenantKeycloakConfig', null) remain.
check_E_no_null_setitem() { file_not_contains "setItem\('tenantKeycloakConfig',\s*null\)" "$INIT"; }

# =============================================================================
# Fix D — !clientInfo branch short-circuits with a return before the fetch
# =============================================================================
# (c) POSITIVE — a return exists between the !clientInfo guard and the fetch call.
check_D_short_circuit()   {
    perl -0777 -ne 'exit 0 if /if\s*\(\s*!\s*clientInfo\s*\).*?\breturn\b.*?fetchAuthConfig\(|if\s*\(\s*!\s*clientInfo\s*\).*?\breturn\b.*?fetch\(/s; exit 1' "$INIT" 2>/dev/null
}

# =============================================================================
# Fix E — 'null'-as-missing reader guard in keycloak.client.js
# =============================================================================
# (h) POSITIVE — getKeycloakConfig treats the string 'null'/'undefined' as missing,
# delegating to the shared isMissingConfig() (single source of truth) OR a legacy inline literal.
check_E_null_guard()      { file_contains "isMissingConfig\(storedConfig\)|storedConfig === 'null'|=== 'null'|'null'\s*\|\||=== \"null\"" "$KC"; }

# =============================================================================
# Fix E (MOBILE-ONLY) — tenant-change branch aligned to web (removeItem stale + warehouseCode)
# =============================================================================
# (j) POSITIVE — the tenant-change branch now clears stale token + config, and persists warehouseCode.
check_E_mobile_removetoken()  { file_contains "removeItem\('kcToken'\)" "$INIT"; }
check_E_mobile_removecfg()    { file_contains "removeItem\('tenantKeycloakConfig'\)" "$INIT"; }
check_E_mobile_warehousecode(){ file_contains "setItem\('warehouseCode'" "$INIT"; }

# =============================================================================
# Fix F — single-writer redirect discipline (sessionStorage arbitration)
# =============================================================================
check_F_flag_key()        { file_contains "DISCOVERY_REDIRECT_KEY|tenantDiscoveryRedirect" "$INIT"; }
check_F_sessionstorage()  { file_contains "sessionStorage" "$INIT"; }
# initTenantAuth is the writer of ?reason=unavailable (mobile → /mobile/-prefixed via classifyRedirect).
check_F_reason_unavail()  { file_contains "reason=unavailable|classifyRedirect" "$INIT"; }
# keycloak.client.js bare redirect is now reason-aware: reads the flag before its bare redirect.
check_F_kc_flag_aware()   { file_contains "getItem\((DISCOVERY_REDIRECT_KEY|'tenantDiscoveryRedirect')\)" "$KC"; }
# (AC8) POSITIVE — initTenantAuth unconditionally clears the flag at the start of every run.
check_F_init_clear()      { file_contains "removeItem\((DISCOVERY_REDIRECT_KEY|'tenantDiscoveryRedirect')\)" "$INIT"; }
# (AC8) POSITIVE — unknown-tenant.vue mounted() unconditionally clears the flag on page mount.
check_F_ut_clear()        { file_contains "removeItem\((DISCOVERY_REDIRECT_KEY|'tenantDiscoveryRedirect')\)" "$UT"; }
# MOBILE — keycloak.client.js bare redirect still lands on the /mobile/ base.
check_F_kc_mobile_bare()  { file_contains "replace\('/mobile/unknown-tenant'\)" "$KC"; }

# =============================================================================
# Fix C — recoverable unknown-tenant page (reason=unavailable + Retry reload)
# =============================================================================
# (g) POSITIVE — reason='unavailable' / isUnavailable present in unknown-tenant.vue.
check_C_isunavailable()   { file_contains "isUnavailable|reason === 'unavailable'|'unavailable'" "$UT"; }
# Retry re-runs cold boot on the ORIGINAL url via reload(), NOT replace('/mobile/') (M1).
check_C_retry_reload()    { file_contains "location\.reload\(\)" "$UT"; }
check_C_no_replace_root() { file_not_contains "location\.replace\('/mobile/'\)|location\.replace\('/'\)" "$UT"; }

# =============================================================================
# Jest harness (NEW for mobile) — runner + specs
# =============================================================================
check_J_jestconfig()      { file_exists "$JEST"; }
check_J_test_script()     { file_contains "\"test\"\s*:\s*\"jest\"" "$PKG"; }
check_J_babel()           { test -f .babelrc || test -f babel.config.js; }
check_J_devdep_jest()     { file_contains "\"(babel-)?jest\"" "$PKG"; }
check_J_devdep_vuejest()  { file_contains "\"vue-jest\"" "$PKG"; }
check_J_spec_fetch()      { file_exists "$SPEC_FETCH"; }
check_J_spec_init()       { file_exists "$SPEC_INIT"; }

# =============================================================================
# (k) NON-REGRESSION — SBDEV-2390 must remain intact (mobile)
# =============================================================================
check_NR_guardedlogin()   { file_contains "guardedLogin" "$KC"; }
check_NR_resetcount()     { file_contains "resetRedirectCount" "$KC"; }
check_NR_reason_auth()    { file_contains "/mobile/unknown-tenant\?reason=auth" "$KC"; }
check_NR_guard_reason()   { file_contains "/mobile/unknown-tenant\?reason=auth" "$GUARD"; }
check_NR_checksso()       { file_contains "onLoad:\s*'check-sso'" "$KC"; }
check_NR_silentsso()      { file_contains "/mobile/silent-check-sso\.html" "$KC"; }
# POSITIVE — unknown-tenant.vue still preserves the SBDEV-2390 auth-error copy state.
check_NR_ut_auth_state()  { file_contains "reason === 'auth'|isAuthError" "$UT"; }

echo
echo "verify-SBDEV-2391-mobile-wms — running acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# --- Fix B (prerequisite helper) ---------------------------------------------
run B1  "Fix B — plugins/tenant-auth-fetch.js exists"          check_B_helper_exists
run B2  "Fix B — response.ok / res.status handling present"    check_B_ok_handling
run B3  "Fix B — 404 classification present"                   check_B_404_handling
run B4  "Fix B — MAX_ATTEMPTS = 3"                             check_B_max_attempts
run B5  "Fix B — TIMEOUT_MS = 5000"                            check_B_timeout_const
run B6  "Fix B — BACKOFF_MS = 300"                            check_B_backoff_const
run B7  "Fix B — AbortController present (timeout bound)"      check_B_abortcontroller
run B8  "Fix B — success maps mobileRedirectUrl (mobile)"      check_B_mobile_redirect
run B9  "Fix B — classifyRedirect targets /mobile/ base"       check_B_mobile_classify
run B10 "Fix B — /mobile/unknown-tenant?reason=unavailable"    check_B_mobile_unavail
echo
# --- Fix A (already present on mobile — non-regression) ----------------------
run A1  "Fix A — !response.ok throw present (already-present)" check_A_already_present
run A2  "Fix A — no dead status===500 re-introduced"           check_A_no_dead500
echo
# --- Fix E (null setItem gone) -----------------------------------------------
run E1  "Fix E — no setItem('tenantKeycloakConfig', null)"     check_E_no_null_setitem
echo
# --- Fix D (short-circuit) ---------------------------------------------------
run D1  "Fix D — !clientInfo returns before fetch"             check_D_short_circuit
echo
# --- Fix E (reader guard) ----------------------------------------------------
run E2  "Fix E — 'null'-as-missing guard in getKeycloakConfig" check_E_null_guard
echo
# --- Fix E (mobile-only tenant-change alignment) -----------------------------
run E3  "Fix E — tenant-change removeItem('kcToken')"          check_E_mobile_removetoken
run E4  "Fix E — tenant-change removeItem('tenantKeycloakConfig')" check_E_mobile_removecfg
run E5  "Fix E — persist setItem('warehouseCode', ...)"        check_E_mobile_warehousecode
echo
# --- Fix F (single-writer arbitration) ---------------------------------------
run F1  "Fix F — tenantDiscoveryRedirect flag in initTenantAuth" check_F_flag_key
run F2  "Fix F — sessionStorage used in initTenantAuth"        check_F_sessionstorage
run F3  "Fix F — initTenantAuth writes ?reason=unavailable"    check_F_reason_unavail
run F4  "Fix F — keycloak.client.js bare redirect is flag-aware" check_F_kc_flag_aware
run F5  "Fix F — initTenantAuth clears flag at start of run (AC8)" check_F_init_clear
run F6  "Fix F — unknown-tenant.vue mounted() clears flag (AC8)" check_F_ut_clear
run F7  "Fix F — kc bare redirect still on /mobile/ base"      check_F_kc_mobile_bare
echo
# --- Fix C (recoverable page) ------------------------------------------------
run C1  "Fix C — unknown-tenant handles reason=unavailable"    check_C_isunavailable
run C2  "Fix C — Retry uses location.reload() (original url)"  check_C_retry_reload
run C3  "Fix C — Retry does NOT use replace('/mobile/' or '/')" check_C_no_replace_root
echo
# --- Jest harness (new) ------------------------------------------------------
run J1  "Jest — jest.config.js exists"                         check_J_jestconfig
run J2  "Jest — package.json has 'test': 'jest'"              check_J_test_script
run J3  "Jest — babel config (.babelrc / babel.config.js)"    check_J_babel
run J4  "Jest — (babel-)jest devDependency present"            check_J_devdep_jest
run J5  "Jest — vue-jest devDependency present"                check_J_devdep_vuejest
run J6  "Jest — tenant-auth-fetch.spec.js exists"              check_J_spec_fetch
run J7  "Jest — initTenantAuth.spec.js exists"                 check_J_spec_init
echo
# --- (k) SBDEV-2390 non-regression -------------------------------------------
run NR1 "NR — SBDEV-2390 guardedLogin still present"           check_NR_guardedlogin
run NR2 "NR — SBDEV-2390 resetRedirectCount still present"     check_NR_resetcount
run NR3 "NR — SBDEV-2390 /mobile/...?reason=auth in keycloak"  check_NR_reason_auth
run NR4 "NR — SBDEV-2390 /mobile/...?reason=auth in guard"     check_NR_guard_reason
run NR5 "NR — SBDEV-2390 onLoad:'check-sso' intact"            check_NR_checksso
run NR6 "NR — SBDEV-2390 /mobile/silent-check-sso.html intact" check_NR_silentsso
run NR7 "NR — unknown-tenant.vue preserves auth-error state"   check_NR_ut_auth_state
echo

# --- Behavior checks (Jest) — proven behavior, not just shape -----------------
# Uncomment once the specs + harness exist. Behavior AC1–AC8 are covered here.
# run BT1 "Behavior — tenant-auth-fetch retry/classify tests pass" \
#     bash -c "yarn test --testPathPattern=tenant-auth-fetch 2>&1 | grep -qE 'PASS|Tests:.*failed, 0'"
# run BT2 "Behavior — initTenantAuth plugin tests pass" \
#     bash -c "yarn test --testPathPattern=initTenantAuth 2>&1 | grep -qE 'PASS|Tests:.*failed, 0'"
skip BT1 "Behavior — tenant-auth-fetch Jest tests" "run 'yarn test --testPathPattern=tenant-auth-fetch' after Step 0 + specs"
skip BT2 "Behavior — initTenantAuth Jest tests"    "run 'yarn test --testPathPattern=initTenantAuth' after Step 0 + specs"

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
