#!/usr/bin/env bash
# SBDEV-3142 — AC-1 live probe: are the 19 POST/GET-as-query report/monitor reads reachable by a
# user who is NOT entitled to the corresponding screen?
#
# Run this BEFORE any fix (mode: baseline) and AGAIN after (mode: gated). The pre-fix run IS the
# AC-1 evidence; the post-fix run is the regression proof. A row that has never been seen to flip
# proves nothing, so both runs are mandatory.
#
# Usage:
#   PW='<dev password>' ./probe-wms2-report-read-gating-dev.sh baseline   # expect the exposure
#   PW='<dev password>' ./probe-wms2-report-read-gating-dev.sh gated      # expect 403 for deprived
#
# ─────────────────────────────────────────────────────────────────────────────────────────────────
# ⚠️ WHY THIS MEASURES BYTES, NOT JUST STATUS CODES.
# A 200 that streams an empty result set is NOT an exposure — this estate has already been burned
# by treating an advertised capability as an exploitable one. Every export row therefore records
# the response SIZE. "200 with 0 bytes" is reported as INCONCLUSIVE, not as a confirmed leak, and
# needs a different orderBatchId / a seeded dataset before AC-1 can be ticked on that row.
#
# ⚠️ THE ACCOUNT CHOICE IS LOAD-BEARING — it is the whole instrument.
# Measured 2026-08-31 against dev_wh01_om1 (tenant wineco / facility wsl) with the exact production
# query (UserRepository.getAllRoles — the five-table mywms_user→group→role→function join that
# AccessService.checkAnyAccess uses), NOT a hand-rolled approximation:
#
#   wmstest         0 fns  — holds NOTHING. The deprived subject: every gated row must 403 for it.
#
#   🔴 CORRECTED 2026-09-01 (SBDEV-3155). This seat used to be `truckloading` on the strength of a
#   measurement showing "4 fns, holds none of the five". IT NO LONGER HOLDS: truckloading was
#   re-measured at **35 functions**, including WEB_UI_VIEW_TRANSFER_ORDER, _INVENTORY_RECORD,
#   _STOCK_UNIT_LOCK_OVERVIEW, _FLOWBIN_MONITOR, _PARCEL_MONITOR, _PARCEL_PICKING,
#   _STOCK_UNIT_RECORD, _UNIT_LOAD_RECORD and _STORAGE_LOCATION — 9 of the 12 this script assumes it
#   lacks. Somebody edits groups on DEV; grants are NOT stable between sessions. Every deprived row
#   here was therefore compromised, and a run would have reported failures that looked like broken
#   gates. A ZERO-function user is the right seat because zero is a floor and cannot drift downward.
#   RE-DERIVE THE GRANTS (query below) BEFORE EVERY RUN rather than trusting this comment.
#   sbtest         35 fns  — THE DIFFERENTIAL SUBJECT, and two-directional:
#                              LACKS  WEB_UI_VIEW_CLUB_LINE, WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW
#                              HOLDS  WEB_UI_VIEW_INVENTORY_RECORD, _STOCK_UNIT_LOCK_OVERVIEW,
#                                     _TRANSFER_ORDER
#                            So post-fix it must be DENIED on /clubLine/* and exportReceiving and
#                            ALLOWED on exportInventory, exportLock and /transfers/*. A gate that
#                            denies it everything is over-gated; one that allows it everything is
#                            inert. NEITHER failure is visible with only a deprived account — which
#                            is why this account, not a zero-function one, is the instrument.
#   panderson      80 fns  — sb_admin, the entitled control
#
# Account selection measured 2026-08-31; all three authenticate with the same dev password.
# (marthamina / estellavasquez were the first draft's choices and are NOT usable — they do not
# share the dev password. josiemarks and sbuser2 likewise fail.)
#
# Substituting an entitled user for `wmstest` or `sbtest` makes every row pass regardless of whether the
# code is correct. That is a vacuous green and it is the specific mistake this script exists to
# prevent. Re-verify the grants before trusting a run:
#   SELECT u.name, count(DISTINCT f.name) FROM mywms_user u
#     JOIN mywms_group_mywms_user gu ON u.id=gu.userlist_id
#     JOIN mywms_group_mywms_role  gr ON gr.grouplist_id=gu.grouplist_id
#     JOIN mywms_role_mywms_function rf ON rf.rolelist_id=gr.rolelist_id
#     JOIN mywms_function f ON rf.functionlist_id=f.id
#   WHERE u.name IN ('wmstest','sbtest','panderson') GROUP BY u.name;
#
# ⚠️ WINECO PRODUCTION LACKS WEB_UI_VIEW_PARCEL_PICKING ENTIRELY (79 functions, 93 users, measured
# 2026-08-31 on wh01_om1). A gate on that constant denies EVERY WineCo prd user. It affects rows
# exportParcelPicking and parcelPickingView here — and `reprintLabels`, which already carries it on
# develop. Seed the function before any release that carries these gates.
#
# ⚠️ THE DUAL MAPPING IS REAL AND BOTH PREFIXES ARE PROBED.
# DashboardController extends ReportController, so all 13 ReportController-declared handlers answer
# on BOTH /v3/report/<p> and /v3/dashboard/<p> — 26 paths for 13 methods, confirmed from
# RequestMappingHandlerMapping (target/surface-inventory.tsv), not from grep. The interceptor keys on
# getMethod().getDeclaringClass(), so ONE method-level annotation covers both; this script probes both
# anyway, because that claim is exactly the kind that must be measured rather than reasoned about.
#
# ⚠️ WHAT THIS SCRIPT CANNOT SEE. Stated so nobody reads a green as more than it is:
#   - It probes the DEV deployment. Confirming DEV runs the build under test is separate and is NOT
#     black-box for a behaviour-preserving change — check the deployed image, or a new metric tag.
#   - It cannot distinguish "gate correct" from "gate denies everyone", except via the sbtest rows in
#     section D. Drop those and the whole run becomes compatible with a deny-everything gate.
#   - /rest/** is deliberately NOT probed: internal-only WMS↔OMS, JWT deferred, ruled not-a-live-
#     exposure 2026-08-27. Do not add rows for it.
# ─────────────────────────────────────────────────────────────────────────────────────────────────
set -u

MODE="${1:-baseline}"
case "$MODE" in
  baseline|gated) ;;
  *) echo "usage: PW='...' $0 {baseline|gated}" >&2; exit 2 ;;
esac

API=https://wms-api.dev.sbo.li
KC=https://kc2.dev.sbo.li/realms/wineco/protocol/openid-connect/token
PW="${PW:?set PW to the dev password}"
TEN='X-Tenant-ID: wineco'
FAC='facility_code: wsl'

# Live ids, measured 2026-08-31 on dev_wh01_om1. If a row returns 0 bytes, re-derive these first —
# an empty dataset looks exactly like a closed endpoint.
CLUB_BATCH=30750403      # type=CLUB, state=700
XFER_BATCH=30704100      # type=TRANSFER_INTRACOMPANY, has 1 customerorder
EXPORT_BODY='{"offset":0,"limit":50}'

pass=0; fail=0; incon=0

tok() { curl -s --max-time 20 -X POST "$KC" -d grant_type=password -d client_id=om1 \
        --data-urlencode "username=$1" --data-urlencode "password=$PW" \
        | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))"; }

# probe <label> <token> <method> <path> <body|-> <expect-code>
probe() {
  local label="$1" tokv="$2" verb="$3" path="$4" body="$5" want="$6"
  local out code size
  out=$(mktemp)
  if [ "$body" = "-" ]; then
    code=$(curl -s -o "$out" -w '%{http_code}' --max-time 45 -X "$verb" \
           -H "Authorization: Bearer $tokv" -H "$TEN" -H "$FAC" "$API$path")
  else
    code=$(curl -s -o "$out" -w '%{http_code}' --max-time 45 -X "$verb" \
           -H "Authorization: Bearer $tokv" -H "$TEN" -H "$FAC" \
           -H 'Content-Type: application/json' -d "$body" "$API$path")
  fi
  size=$(wc -c < "$out" | tr -d ' ')

  if [ "$code" != "$want" ]; then
    printf '  FAIL  %-62s got %s (%s B), want %s\n' "$label" "$code" "$size" "$want"
    fail=$((fail+1))
  elif [ "$want" = "200" ] && { [ "$size" -lt 48 ] \
        || grep -qE '"totalElements" *: *0|"content" *: *\[\]|^\[\]$' "$out"; }; then
    # 200 but an EMPTY result set: reachable, but not demonstrably a data leak. A byte-count
    # threshold alone is not enough — measured 2026-08-31, `{"content":[],"totalElements":0}` is
    # exactly 32 bytes and slipped past a `-lt 32` test, reporting an empty page as a confirmed
    # leak. Assert on the CONTENT, not the size.
    printf '  INCON %-62s 200 but empty result set (%s B) — reachable, leak NOT demonstrated\n' "$label" "$size"
    incon=$((incon+1))
  else
    printf '  PASS  %-62s %s (%s B)\n' "$label" "$code" "$size"
    pass=$((pass+1))
  fi
  rm -f "$out"
}

T_NONE=$(tok wmstest)           # 0 fns, holds nothing (see the banner: NOT truckloading)
T_PART=$(tok sbtest)            # 35 fns, holds INVENTORY_RECORD/LOCK/TRANSFER, lacks CLUB_LINE/RECV
T_ADM=$(tok panderson)          # sb_admin control
for v in T_NONE:wmstest T_PART:sbtest T_ADM:panderson; do
  n="${v%%:*}"; u="${v##*:}"
  [ -n "${!n}" ] || { echo "token fetch FAILED for $u — cannot proceed (wrong PW, or account disabled)"; exit 2; }
done

# In baseline mode every endpoint is expected OPEN to everyone — that IS the defect.
# In gated mode the deprived user must be refused and the entitled one must still work.
if [ "$MODE" = baseline ]; then D=200; else D=403; fi

echo "SBDEV-3142 read-gating probe — mode=$MODE — $(date -u +%FT%TZ)"
echo "  wmstest(0 fns, none) / sbtest(35, holds INV+LOCK+TRANSFER) / panderson(80, sb_admin)"
echo
echo "── A. The 10 dual-mapped exports, deprived user, BOTH prefixes (20 rows)"
for e in exportInventory exportLock exportReceiving exportSkuLocation exportFlowbin \
         exportParcelPicking exportOutboundParcel exportStockUnitRecord \
         exportContainerRecord exportStorageLocations; do
  probe "report/$e  [wmstest]"    "$T_NONE" POST "/v3/report/$e"    "$EXPORT_BODY" "$D"
  probe "dashboard/$e  [wmstest]" "$T_NONE" POST "/v3/dashboard/$e" "$EXPORT_BODY" "$D"
done

echo
echo "── B. The 3 dual-mapped GET monitor views, deprived user (6 rows)"
# ⚠️ page+size are REQUIRED (@RequestParam("page")/("size") with no default on all three).
# Omitting them returns 400 BEFORE the gate is consulted — and a 400 proves nothing about
# exposure. Measured 2026-08-31: the first draft of this script omitted them and produced six
# credible-looking FAILs that were entirely its own bug (panderson 400'd too).
VIEW_Q='?page=0&size=50'
for v in flowbinMonitorView parcelPickingView parcelMonitorView; do
  probe "report/$v  [wmstest]"    "$T_NONE" GET "/v3/report/$v$VIEW_Q"    - "$D"
  probe "dashboard/$v  [wmstest]" "$T_NONE" GET "/v3/dashboard/$v$VIEW_Q" - "$D"
done

echo
echo "── C. ClubLine + Transfers query-shaped reads, deprived user (7 rows, incl. row 20)"
probe "clubLine/skus  [wmstest]"       "$T_NONE" POST /v3/clubLine/skus       "{\"orderBatchId\":$CLUB_BATCH}" "$D"
probe "clubLine/unitLoads  [wmstest]"  "$T_NONE" POST /v3/clubLine/unitLoads  "{\"orderBatchId\":$CLUB_BATCH,\"onlyStagingLocation\":false}" "$D"
probe "clubLine/parcels  [wmstest]"    "$T_NONE" POST /v3/clubLine/parcels    "{\"orderBatchId\":$CLUB_BATCH}" "$D"
probe "transfers/unitLoads  [wmstest]" "$T_NONE" POST /v3/transfers/unitLoads "{\"orderBatchId\":$XFER_BATCH,\"onlyTransferLocation\":false}" "$D"
probe "transfers/parcels  [wmstest]"   "$T_NONE" POST /v3/transfers/parcels   "{\"orderBatchId\":$XFER_BATCH}" "$D"
probe "transfers/availableTransferLanes  [wmstest]" "$T_NONE" POST /v3/transfers/availableTransferLanes "{\"orderBatchId\":$XFER_BATCH}" "$D"
# Row 20, taken into scope by Nam 2026-08-31. A GET, and `orderBatchId` is a REQUIRED @RequestParam
# (`@RequestParam("orderBatchId") Long orderBatchId`) — omit it and you get a 400 that proves nothing.
probe "transfers/skus (GET)  [wmstest]"            "$T_NONE" GET "/v3/transfers/skus?orderBatchId=$XFER_BATCH" - "$D"

echo
echo "── D. DIFFERENTIAL (the load-bearing section) — sbtest LACKS CLUB_LINE + RECEIVED_STOCK_OVERVIEW"
echo "     but HOLDS INVENTORY_RECORD + LOCK_OVERVIEW + TRANSFER_ORDER. Post-fix it must be DENIED"
echo "     on the first two rows and ALLOWED on the last three. All-denied = over-gated;"
echo "     all-allowed = inert. Neither is visible with a deprived-only account."
probe "clubLine/skus  [sbtest: lacks CLUB_LINE]"          "$T_PART" POST /v3/clubLine/skus "{\"orderBatchId\":$CLUB_BATCH}" "$D"
probe "report/exportReceiving  [sbtest: lacks RECV]"      "$T_PART" POST /v3/report/exportReceiving "$EXPORT_BODY" "$D"
probe "report/exportInventory  [sbtest: HOLDS INV]"       "$T_PART" POST /v3/report/exportInventory "$EXPORT_BODY" 200
probe "report/exportLock  [sbtest: HOLDS LOCK]"           "$T_PART" POST /v3/report/exportLock "$EXPORT_BODY" 200
probe "transfers/parcels  [sbtest: HOLDS TRANSFER]"       "$T_PART" POST /v3/transfers/parcels "{\"orderBatchId\":$XFER_BATCH}" 200
probe "transfers/skus  [sbtest: HOLDS TRANSFER]"         "$T_PART" GET "/v3/transfers/skus?orderBatchId=$XFER_BATCH" - 200

echo
echo "── E. CONTROL — the entitled admin must keep working in BOTH modes."
echo "     A gated run where these fail means the fix broke the feature, not that it closed a hole."
probe "report/exportInventory  [panderson]"     "$T_ADM" POST /v3/report/exportInventory "$EXPORT_BODY" 200
probe "dashboard/exportInventory  [panderson]"  "$T_ADM" POST /v3/dashboard/exportInventory "$EXPORT_BODY" 200
probe "report/parcelMonitorView  [panderson]"   "$T_ADM" GET  "/v3/report/parcelMonitorView?page=0&size=50" - 200
probe "clubLine/skus  [panderson]"              "$T_ADM" POST /v3/clubLine/skus "{\"orderBatchId\":$CLUB_BATCH}" 200

echo
echo "── F. MOBILE SAFETY — DashboardController-DECLARED handlers, which our change must NOT touch."
echo "     These are called by the MOBILE UI. declaringClass is DashboardController, not"
echo "     ReportController, so a method-level annotation on the exports cannot reach them."
echo "     They must return 200 in BOTH modes. A 403 here in gated mode = a 403'd mobile screen."
probe "dashboard/orderMonitorViewSummary  [wmstest]"     "$T_NONE" GET /v3/dashboard/orderMonitorViewSummary - 200
probe "dashboard/replenishMonitorViewSummary  [wmstest]" "$T_NONE" GET /v3/dashboard/replenishMonitorViewSummary - 200

echo
printf 'Result: %d pass, %d fail, %d inconclusive  (mode=%s)\n' "$pass" "$fail" "$incon" "$MODE"
if [ "$MODE" = baseline ]; then
  echo
  echo "Reading a BASELINE run:"
  echo "  Sections A-D all PASS with non-trivial byte counts => the exposure is CONFIRMED. AC-1 met."
  echo "  Any INCON row  => reachable but no data returned; re-derive that row's ids before ticking it."
  echo "  Section F PASS => the mobile-shared handlers are live, so the gated run can prove they survive."
fi
exit $(( fail > 0 ))
