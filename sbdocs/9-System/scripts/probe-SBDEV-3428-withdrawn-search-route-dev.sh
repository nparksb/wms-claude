#!/usr/bin/env bash
# SBDEV-3428 — is the withdrawn SDR search route ACTUALLY gone on dev?
#
#   PW='<dev password>' ./probe-SBDEV-3428-withdrawn-search-route-dev.sh
#
# Confirms live what the MockMvc context lane already pins: after PR #383 (merged 29ce240d),
# `pickingorder/search/getForRapidPickingScanPackage` is withdrawn (exported = false) and answers
# 404 instead of the 500 it gave when its primitive `stateCancelled` was omitted.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# 🔴 WHY THIS SCRIPT EXISTS, AND WHY THE OBVIOUS ONE-LINER IS WORTHLESS.
#
# An UNAUTHENTICATED probe of this route returns 401 — and so does the exported control, because
# Spring Security runs before routing. Measured 2026-09-18, both on the same run:
#
#   GET /v3/pickingorder/search/getForRapidPickingScanPackage?packageName=x  -> 401
#   GET /v3/pickingorder/search/findByStateAndSectionId?state=0&sectionId=1  -> 401
#
# Subject and control identical => the instrument is BLIND, not passing. That is the same failure
# recorded in probe-SBDEV-3321 (both returned 404 and the control "passed" while proving nothing).
# Authentication is not a convenience here; without it the probe cannot answer the question.
#
# ⚠ A CONTROL MUST DISCRIMINATE, NOT MERELY RESPOND. A 404 for a withdrawn route and a 404 for a
# route that never existed — or a typo in this script — are the same response. So the control is an
# exported SIBLING SEARCH ON THE SAME REPOSITORY that must answer 200. If the control is not 200,
# every verdict below is void: it means auth failed, the tenant headers are wrong, or the
# pickingorder surface is gone for an unrelated reason.
#
# ⚠ THE CONTROL MUST RETURN A COLLECTION. `findByNumber` returns Optional<Pickingorder>, and SDR
# answers 404 for an empty Optional — so an empty table would make the control report "route
# missing" and void the run for no reason. `findByStateAndSectionId` returns List, so an empty
# result is 200 with an empty _embedded. Do not "simplify" this to findByNumber.
#
# ⚠ THIS PROBE IS READ-ONLY. Every request is a GET. It cannot modify anything.
set -uo pipefail

API=https://wms-api.dev.sbo.li
KC=https://kc2.dev.sbo.li/realms/wineco/protocol/openid-connect/token
PW="${PW:?set PW to the dev password}"
USER_="${USER_:-panderson}"
TEN='X-Tenant-ID: wineco'
FAC='facility_code: wsl'

# The commit that carries the withdrawal. The probe refuses to grade any other build — a deployed
# image routinely differs from branch HEAD on this stack, and grading a stale one produces a
# confident wrong answer in whichever direction the old code happened to behave.
WANT_SHA="${WANT_SHA:-29ce240db0c9edb747346e2b6fe42287afcd0b63}"

SUBJECT='/v3/pickingorder/search/getForRapidPickingScanPackage?packageName=x'
CONTROL='/v3/pickingorder/search/findByStateAndSectionId?state=0&sectionId=1'
LISTING='/v3/pickingorder/search'

fail=0
note() { printf '  %-6s %s\n' "$1" "$2"; }

printf '== SBDEV-3428 — withdrawn SDR search route, live on dev ==\n'
printf '   subject: %s   tenant: wineco/wsl\n\n' "$USER_"

# ── 0. Which build is actually running? ───────────────────────────────────────────────────────
printf -- '-- 0. PRECONDITION: the deployed build must carry the fix --\n'
VER=$(curl -s --max-time 20 "$API/api/public/version" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('self',{}).get('version',''))" 2>/dev/null)
printf '  deployed: %s\n' "${VER:-<unreachable>}"
case "$VER" in
  *"$WANT_SHA"*) note ok "carries $WANT_SHA" ;;
  *) note ABORT "expected $WANT_SHA — this build predates or postdates the fix; verdicts would be void"
     exit 2 ;;
esac
echo

# ── 1. Token ──────────────────────────────────────────────────────────────────────────────────
T=$(curl -s --max-time 20 -X POST "$KC" -d grant_type=password -d client_id=om1 \
      --data-urlencode "username=$USER_" --data-urlencode "password=$PW" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
[ -n "$T" ] || { echo "ABORT: no token for $USER_ — check PW"; exit 3; }
H=(-H "Authorization: Bearer $T" -H "$TEN" -H "$FAC")

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 30 "${H[@]}" "$API$1"; }

# ── 2. The control must discriminate ──────────────────────────────────────────────────────────
printf -- '-- 1. CONTROL: an exported sibling search on the SAME repository --\n'
C=$(code "$CONTROL")
printf '  GET %s -> %s\n' "${CONTROL%%\?*}" "$C"
if [ "$C" = 200 ]; then
  note ok 'the pickingorder search surface is live and reachable as this user'
else
  note ABORT "control is $C, not 200 — auth, tenant headers, or the surface is broken. EVERY verdict below is void."
  exit 2
fi
echo

# ── 3. AC-1: the withdrawn route ──────────────────────────────────────────────────────────────
printf -- '-- 2. AC-1: the withdrawn route (was 500 pre-fix, must now be 404) --\n'
S=$(code "$SUBJECT")
printf '  GET %s -> %s\n' "${SUBJECT%%\?*}" "$S"
case "$S" in
  404) note PASS 'withdrawn — method-level exported = false gives 404 (405 would mean CLASS-level)' ;;
  500) note FAIL 'STILL 500 — the withdrawal is not in the running build'; fail=1 ;;
  405) note FAIL 'got 405 — that is the CLASS-level withdrawal shape; the whole repository is unexported'; fail=1 ;;
  200) note FAIL 'route still resolves — not withdrawn'; fail=1 ;;
  *)   note FAIL "unexpected $S"; fail=1 ;;
esac
echo

# ── 4. AC-2: the HAL search listing ───────────────────────────────────────────────────────────
printf -- '-- 3. AC-2: the rel is absent from the search listing, sibling present as control --\n'
BODY=$(curl -s --max-time 30 "${H[@]}" "$API$LISTING")
HAS_SUBJ=$(printf '%s' "$BODY" | grep -c 'getForRapidPickingScanPackage' || true)
HAS_CTRL=$(printf '%s' "$BODY" | grep -c 'findByStateAndSectionId'       || true)
printf '  listing contains findByStateAndSectionId (control): %s\n' "$HAS_CTRL"
printf '  listing contains getForRapidPickingScanPackage    : %s\n' "$HAS_SUBJ"
if [ "$HAS_CTRL" -eq 0 ]; then
  note ABORT 'control rel absent from the listing — the listing did not render; the line below proves nothing'
  fail=1
elif [ "$HAS_SUBJ" -eq 0 ]; then
  note PASS 'rel absent while a sibling is present — withdrawn from the published surface'
else
  note FAIL 'rel still advertised in the HAL listing'; fail=1
fi
echo

# ── 5. Verdict ────────────────────────────────────────────────────────────────────────────────
if [ "$fail" -eq 0 ]; then
  printf 'VERDICT: PASS — AC-1 and AC-2 confirmed live on dev, build %s\n' "$WANT_SHA"
else
  printf 'VERDICT: FAIL — see the FAIL lines above\n'
fi
exit "$fail"
