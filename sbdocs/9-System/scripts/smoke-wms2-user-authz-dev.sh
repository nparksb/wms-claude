#!/usr/bin/env bash
# wms2 /v3/user authorization smoke — the four-cell matrix, against a LIVE dev deployment.
#
#   non-admin: bootstrap reads OPEN      |  non-admin: gated surface DENIED
#   admin:     gated surface ALLOWED     |  control:   sibling guarded controller ALLOWED
#
# Deliberately NOT ticket-named. Originally written for SBDEV-3063 (@PublicHandler / GUARDED
# membership) and kept past that ticket's archival because it is the only automated check of this
# authorization surface against a real deployment with real Keycloak tokens — no unit test reaches it.
# Two tickets queued behind it touch these exact endpoints: SBDEV-3071 (scoping getAllRoles/isWmsUser
# to the caller) and SBDEV-3017 slice B (the Spring Data REST half of /v3/user). Re-run it after either.
#
# ⚠️ THE ACCOUNT CHOICE IS LOAD-BEARING. `sbtest` holds 35 functions and NOT
# WEB_UI_VIEW_USER_MANAGEMENT; `panderson` holds all 80 and IS sb_admin. Swapping in an admin for the
# non-admin rows makes every row pass regardless of whether the code is correct — that is a vacuous
# green, and it is the specific mistake this script exists to prevent. Verify with:
#   SELECT ... FROM mywms_user ... -- see the plan's §6.5, or the SBDEV-3063 ticket comments.
#
# CONFIRMING THE DEPLOYED BUILD contains a given change is separate and is not black-box for
# behaviour-preserving changes. For SBDEV-3063 the tell was the metric it introduced:
#   curl -s -H "Authorization: Bearer $ADMIN_TOKEN" -H "X-Tenant-ID: wineco" -H "facility_code: wsl" \
#     https://wms-api.dev.sbo.li/actuator/metrics | grep -o 'wms2.authz.public'
# /actuator/metrics needs an sb_admin token; it 401s for an ordinary user.
#
# Usage:  PW='...' ./smoke-wms2-user-authz-dev.sh
set -u
API=https://wms-api.dev.sbo.li
KC=https://kc2.dev.sbo.li/realms/wineco/protocol/openid-connect/token
PW="${PW:?set PW to the dev password}"
pass=0; fail=0

tok() { curl -s --max-time 15 -X POST "$KC" -d grant_type=password -d client_id=om1 \
        --data-urlencode "username=$1" --data-urlencode "password=$PW" \
        | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))"; }

check() { # name expected-code token path
  local got
  got=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        -H "Authorization: Bearer $3" -H "X-Tenant-ID: wineco" -H "facility_code: wsl" "$API/v3/$4")
  if [ "$got" = "$2" ]; then printf '  PASS  %-52s %s\n' "$1" "$got"; pass=$((pass+1))
  else printf '  FAIL  %-52s got %s, want %s\n' "$1" "$got" "$2"; fail=$((fail+1)); fi
}

T_NON=$(tok sbtest); T_ADM=$(tok panderson)
[ -n "$T_NON" ] && [ -n "$T_ADM" ] || { echo "token fetch failed"; exit 2; }

echo "SBDEV-3063 dev smoke — sbtest (non-admin, no WEB_UI_VIEW_USER_MANAGEMENT) / panderson (admin)"
# THE regression: without these two open, 61 of 99 users cannot log in.
check "non-admin: isWmsUser OPEN"                200 "$T_NON" "user/isWmsUser/sbtest"
check "non-admin: getAllRoles OPEN"              200 "$T_NON" "user/getAllRoles/sbtest"
# The surface must not have been opened by the class-level move.
check "non-admin: getDetails DENIED"             403 "$T_NON" "user/getDetails"
check "non-admin: userDetailsById DENIED"        403 "$T_NON" "user/userDetailsById/52610"
# The nine method-level annotations were deleted; the class-level one must still gate FOR admins.
check "admin: getDetails ALLOWED"                200 "$T_ADM" "user/getDetails"
check "admin: userDetailsById ALLOWED"           200 "$T_ADM" "user/userDetailsById/52610"
check "admin: bootstrap reads ALLOWED"           200 "$T_ADM" "user/getAllRoles/panderson"
# Control: a sibling GUARDED controller this ticket did not touch.
check "control: userRole ALLOWED for admin"      200 "$T_ADM" "userRole"

echo "  ---"
echo "  Result: $pass pass, $fail fail"
[ "$fail" -eq 0 ] || exit 1
