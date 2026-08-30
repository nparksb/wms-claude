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

# Method-aware variant, for the SDR rows below. Same shape as check(), plus a verb and an optional body.
checkm() { # name expected-code token method path [body]
  local got
  if [ -n "${6:-}" ]; then
    got=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X "$4" \
          -H "Authorization: Bearer $3" -H "X-Tenant-ID: wineco" -H "facility_code: wsl" \
          -H 'Content-Type: application/json' -d "$6" "$API/v3/$5")
  else
    got=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X "$4" \
          -H "Authorization: Bearer $3" -H "X-Tenant-ID: wineco" -H "facility_code: wsl" "$API/v3/$5")
  fi
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


# ── SBDEV-3157 · Spring Data REST (Class A). Added 2026-08-28. ────────────────────────────────────
#
# ⚠️ SAFETY: EVERY WRITE ROW BELOW USES A DELIBERATELY NON-EXISTENT ID (999999999). Nothing is
# created, modified or destroyed. DO NOT substitute a real id "to make it more realistic" — a live
# DELETE here removes production-shaped data from dev, and the row proves exactly as much with a
# missing id. That is the whole design: the question is whether AUTHORIZATION stops the request,
# and the answer is visible in WHICH rejection you get, before the row is ever reached.
#
#   403 -> authorization refused it            (the endpoint is GATED)
#   405 -> the verb is withdrawn by SDR        (ExposureConfiguration took it away)
#   404 -> the request reached the repository  (NOTHING gated it; the row simply does not exist)
#
# So 404 on a write is the FINDING, not a passing row. These rows encode today's measured state, so
# they will start FAILING the moment the withdrawal or the gate lands — at which point update the
# expectations in the same commit. A row that still expects 404 after the fix is a stale row.
#
# MEASURED ON DEV 2026-08-29, after SBDEV-3157's write half reached dev (merge `79320399`). The four
# rows did NOT move together, and that split was the predicted result and the actual one:
#   itemdata  DELETE  404 -> 405   CONFIRMED. In the withdrawn 47; nothing writes to it, verb removed
#   stockunit DELETE  404 -> 405   CONFIRMED. same
#   client    DELETE  404 == 404   CONFIRMED UNCHANGED. `client` is one of the ELEVEN that must STAY
#   sysprop   PATCH   404 == 404   CONFIRMED UNCHANGED. writable (a live UI writer at its SDR path),
#                                  so the withdrawal could not touch these two. They close only when
#                                  the GATE lands — the READ half — and then 404 -> 403.
# Two rows moving to 405 while two stayed at 404 was the correct outcome, not a partial failure. Had all
# four moved, something would have withdrawn a resource that a screen writes to.
#
# Corroborated the same run by OPTIONS Allow, read in the NEGATIVE direction only (see the caveat below):
#   /v3/itemdata/{id}  ->  HEAD,GET,OPTIONS                     write verbs gone
#   /v3/client/{id}    ->  HEAD,DELETE,GET,OPTIONS,PUT,PATCH    write verbs retained
#
# ⚠️ AN OPTIONS/Allow READING WOULD NOT DO — IN THE POSITIVE DIRECTION. This estate has measured that
# an advertised capability is not an exploitable one, so an Allow header listing DELETE proves nothing
# about whether a DELETE succeeds. The ABSENCE of a verb is weaker evidence still and is used above
# only as corroboration. A body-free write against a missing id remains the cheapest thing that
# actually distinguishes "refused" from "reached the code", and it is what every row below does.
#
# Account choice is load-bearing here exactly as it is above: `sbtest` is a plain wms_user. If these
# rows are run as `panderson` they prove nothing, because he holds every function.

echo "  --- SBDEV-3157: SDR write half WITHDRAWN on dev; reads + 11 kept-writable still ungated ---"

# CONTROL, and the row that makes the rest non-vacuous: userFunction's write verbs WERE withdrawn
# (RestConfiguration:224-227, SBDEV-3017 §8.12.1). It must answer 405, not 404. If this row returns
# 404 the withdrawal has regressed; if it returns the SAME code as the rows below, the probe cannot
# tell "withdrawn" from "open" and none of its verdicts mean anything.
checkm "control: userFunction DELETE WITHDRAWN"   405 "$T_NON" DELETE "userFunction/999999999"

# The reads. 347 exported searches, none gated — this is the ticket's founding complaint, still live
# after the write half. These two rows are the READ half's open criterion: they must become 403 for a
# caller denied the function. Until then a 200 here is the finding, not a healthy row.
check  "non-admin: SDR itemdata list STILL OPEN"  200 "$T_NON" "itemdata?size=1"
check  "non-admin: SDR sysprop list STILL OPEN"   200 "$T_NON" "sysprop?size=1"

# The writes, post-withdrawal. 47 of the 58 writable resources had their write verbs removed; the other
# 11 kept theirs because a UI writes to them at their SDR path, and those close only via the gate.
checkm "non-admin: SDR itemdata DELETE WITHDRAWN"  405 "$T_NON" DELETE "itemdata/999999999"
checkm "non-admin: SDR stockunit DELETE WITHDRAWN" 405 "$T_NON" DELETE "stockunit/999999999"
checkm "non-admin: SDR client DELETE UNGATED"      404 "$T_NON" DELETE "client/999999999"
checkm "non-admin: SDR sysprop PATCH UNGATED"      404 "$T_NON" PATCH  "sysprop/999999999" '{}'

echo "  ---"
echo "  Result: $pass pass, $fail fail"
echo "  NOTE: a PASS on an *_UNGATED or *_STILL_OPEN row confirms the EXPOSURE, not a healthy system."
[ "$fail" -eq 0 ] || exit 1
