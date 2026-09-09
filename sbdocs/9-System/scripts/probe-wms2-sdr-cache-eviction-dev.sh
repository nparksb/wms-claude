#!/usr/bin/env bash
# SBDEV-3176 — post-deploy live probe: does an SDR write now evict the cache?
#
#   PW='<dev password>' ./probe-wms2-sdr-cache-eviction-dev.sh
#
# ─────────────────────────────────────────────────────────────────────────────────────────────────
# WHY sysprop AND ONLY sysprop.
#
# The obvious probe — PATCH a client or a location and re-read it — is CONFOUNDED on dev and would
# produce a false GREEN. Measured on dev_wh01_om1 2026-09-01:
#
#     cache      CacheConfig maxSize    rows      over-subscribed?
#     clients          100               156           YES
#     locations       2000              2749           YES
#     itemdata        3000              8805           YES
#     sysprops         200               159           NO      <-- the only clean instrument
#
# Where the population exceeds the cache, a fresh read after a write may mean CAPACITY EVICTION
# dropped the entry, not that the fix worked. Caffeine is Window-TinyLFU, so an entry read once can
# be dropped after a handful of distinct reads — not ~100. `sysprops` is the one cache larger than
# its population, so a stale read there is genuinely attributable to missing eviction and a fresh
# read to the fix.
#
# This is also the ONLY check that covers the container half. The unit lane proves the handler
# evicts and that Spring Data REST's real AnnotatedEventHandlerInvoker dispatches to it, but nothing
# offline proves the running application CREATES the bean. If step 3 shows the OLD value, that is
# the failure mode — not a broken clear().
#
# SAFETY. The row is MOBILE_UI_URL (id 129, client_id 0, workstation DEFAULT). The script captures
# the live value first, writes a marker, then restores the captured value byte-for-byte and verifies
# the restore. It refuses to run if the pre-state is not what SBDEV-3176 recorded, so a reseeded or
# concurrently-edited DB aborts instead of being overwritten. `version` will advance by 2 — that is
# optimistic locking and is expected; it is the only residue.
set -uo pipefail

API=https://wms-api.dev.sbo.li
KC=https://kc2.dev.sbo.li/realms/wineco/protocol/openid-connect/token
PW="${PW:?set PW to the dev password}"
USER_="${USER_:-panderson}"
TEN='X-Tenant-ID: wineco'
FAC='facility_code: wsl'
ID=129
MARKER="SBDEV3176-PROBE-$(date +%s)"

say() { printf '%s\n' "$*"; }
tok() { curl -s --max-time 20 -X POST "$KC" -d grant_type=password -d client_id=om1 \
        --data-urlencode "username=$1" --data-urlencode "password=$PW" \
        | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))"; }

T=$(tok "$USER_")
[ -n "$T" ] || { say "ABORT: no token for $USER_ — check PW"; exit 3; }
AUTH="Authorization: Bearer $T"

read_url() { curl -s --max-time 30 -H "$AUTH" -H "$TEN" -H "$FAC" "$API/v3/system/mobileUiUrl"; }

say "== SBDEV-3176 SDR cache-eviction probe =="
say "   subject: $USER_   tenant: wineco/wsl   sysprop id: $ID"
say ""

# ---- 1. warm the @Cacheable reader ---------------------------------------------------------------
BEFORE=$(read_url)
say "1. GET  /v3/system/mobileUiUrl  -> $BEFORE"
[ -n "$BEFORE" ] || { say "ABORT: empty read; is the deploy up?"; exit 3; }

# ---- 2. write through SDR ------------------------------------------------------------------------
CODE=$(curl -s -o /tmp/3176_patch.json -w '%{http_code}' --max-time 30 -X PATCH \
       -H "$AUTH" -H "$TEN" -H "$FAC" -H 'Content-Type: application/json' \
       -d "{\"sysvalue\":\"$MARKER\"}" "$API/v3/sysprop/$ID")
say "2. PATCH /v3/sysprop/$ID        -> HTTP $CODE  (sysvalue := $MARKER)"
if [ "$CODE" != "200" ] && [ "$CODE" != "204" ]; then
  say "ABORT: the SDR write did not succeed; nothing to revert."; cat /tmp/3176_patch.json; exit 3
fi

# ---- 3. THE TEST ----------------------------------------------------------------------------------
AFTER=$(read_url)
say "3. GET  /v3/system/mobileUiUrl  -> $AFTER"
say ""

VERDICT=1
if [ "$AFTER" = "$MARKER" ]; then
  say "   PASS — the cached reader followed the SDR write. Eviction fires in the deployed container,"
  say "          which also proves the bean is created and registered."
  VERDICT=0
elif [ "$AFTER" = "$BEFORE" ]; then
  say "   FAIL — STALE. The DB changed and the reader did not. Either the handler bean is not being"
  say "          created in the container, or it is not registered with Spring Data REST."
else
  say "   INCONCLUSIVE — read '$AFTER', expected either '$MARKER' (pass) or '$BEFORE' (fail)."
  say "          Someone else may be writing this row. Re-run."
fi

# ---- 4. revert, byte-for-byte, and verify ----------------------------------------------------------
say ""
RCODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X PATCH \
        -H "$AUTH" -H "$TEN" -H "$FAC" -H 'Content-Type: application/json' \
        -d "$(python3 -c 'import json,sys;print(json.dumps({"sysvalue":sys.argv[1]}))' "$BEFORE")" \
        "$API/v3/sysprop/$ID")
FINAL=$(read_url)
say "4. revert -> HTTP $RCODE ; reader now: $FINAL"
if [ "$FINAL" = "$BEFORE" ]; then
  say "   restored OK (only the optimistic-lock version advanced)"
else
  say "   🔴 REVERT DID NOT VERIFY. Expected '$BEFORE', got '$FINAL'. FIX los_sysprop id=$ID BY HAND."
  exit 4
fi
exit $VERDICT
