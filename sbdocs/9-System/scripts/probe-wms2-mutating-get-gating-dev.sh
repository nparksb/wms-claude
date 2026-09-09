#!/usr/bin/env bash
# SBDEV-3155 — AC-1 live probe: are the TEN state-changing GETs reachable by a user who is NOT
# entitled to the screen that dispatches them?
#
#   PW='<dev password>' ./probe-wms2-mutating-get-gating-dev.sh baseline   # pre-fix: expect exposure
#   PW='<dev password>' ./probe-wms2-mutating-get-gating-dev.sh gated      # post-deploy: expect 403
#
# ─────────────────────────────────────────────────────────────────────────────────────────────────
# 🔴 WHY EVERY ID BELOW IS DELIBERATELY NON-EXISTENT. READ THIS BEFORE CHANGING ONE.
#
# All ten endpoints MUTATE. Two of them run an entire club batch / transfer. AC-1 as originally
# written ("a live probe against each of the ten") would, executed literally with live ids, run ten
# real state-changing operations against shared DEV — including runClubLine and runTransfer.
#
# It does not need to. Every one of the ten resolves its entity FIRST:
#     findById(id).orElseThrow(() -> new EntityNotFoundException(...))
# and only then calls the mutating service. So a well-formed but NON-EXISTENT id reaches the
# repository and stops there. That is sufficient to answer AC-1's actual question — did the request
# get past authorization? — while being incapable of changing a row.
#
# Verified 2026-09-01 on dev_wh01_om1: customerorder_batch.id=999999999 → 0 rows,
# customerorder_batch.batchid='SBDEV3155-NOSUCH' → 0, customerorder.id=999999999 → 0,
# location.id=999999999 → 0, pickingorder_position.id=999999999 → 0. RE-VERIFY before each run if the
# DB has been reseeded; a live id here turns this probe into ten unlogged production actions.
#
# ⚠ THE IDS MUST STAY NUMERIC. Every path variable except runClubLine's is typed Long. A
# non-numeric id is rejected by Spring's type conversion BEFORE any interceptor runs, yielding 400.
# A 400 proves NOTHING about the gate — this is the exact trap that made six rows of the SBDEV-3142
# probe read as "already protected" when they were wide open. runClubLine takes a String
# (findByBatchid), so it gets a string sentinel; activateBatch takes a String it immediately
# Long.parseLong()s, so it must stay numeric too.
#
# ⚠ THE ASSERTION IS "403 vs NOT-403", NOT AN EXACT STATUS.
# What a handler does with a bad id (404 / 500 / 200-with-an-error-map) is irrelevant and varies —
# EntityNotFoundException is uncaught in most of these bodies while BusinessException is caught and
# rendered as 200. Only "did the gate deny me" matters, and that is exactly the 403 axis.
#
# 🔴 RE-DERIVE THE GRANTS BEFORE EVERY RUN. THEY DRIFT, AND A STALE ASSUMPTION READS AS A BUG.
# Measured the hard way 2026-09-01: this script shipped with `truckloading` as the deprived subject on
# the strength of a query run ~2 hours earlier showing it held 4 functions and none of the three
# constants. By the time the post-deploy run happened it held 35 functions INCLUDING
# WEB_UI_VIEW_TRANSFER_ORDER — the identical grant set to sbtest. The run reported "5 fail" and looked
# exactly like the transfers gate being inert. It was not: the gate was correct and the SCRIPT was
# wrong. A zero-function user was then denied on all ten, which is what actually proved the gate fires.
# DEV is a live system and somebody edits groups on it. Run the SELECT below every time.
#
# ⚠ THE ACCOUNT SET IS THE INSTRUMENT — do not simplify it to one deprived user.
# Measured 2026-09-01 against dev_wh01_om1 with the production five-table join:
#
#   wmstest       0 fns — the DEPRIVED subject. Zero is a floor and cannot drift downward, which is why
#                         it, not truckloading, belongs in this seat. Every row must 403 for it.
#   sbtest       35 fns — THE TWO-DIRECTIONAL DIFFERENTIAL:
#                           LACKS WEB_UI_VIEW_CLUB_LINE, WEB_UI_VIEW_PICKING_POSITION
#                           HOLDS WEB_UI_VIEW_TRANSFER_ORDER
#                         So post-fix it must be DENIED on the 4 clubLine rows + fixPickingPosition
#                         and ALLOWED on the 5 transfers rows. A gate that denies it everything is
#                         over-gated; one that allows it everything is inert. NEITHER failure is
#                         visible with only a deprived account.
#   panderson    80 fns — the entitled CONTROL. If a row 403s for panderson the gate is wrong, and
#                         if a row 403s for EVERYONE this is the only account that shows it.
#
# Substituting an entitled user for wmstest/sbtest makes every row pass regardless of correctness.
# Re-verify the grants before trusting a run:
#   SELECT u.name, count(DISTINCT f.name),
#          bool_or(f.name='WEB_UI_VIEW_CLUB_LINE'), bool_or(f.name='WEB_UI_VIEW_TRANSFER_ORDER'),
#          bool_or(f.name='WEB_UI_VIEW_PICKING_POSITION')
#     FROM mywms_user u
#     LEFT JOIN mywms_group_mywms_user gu ON u.id=gu.userlist_id
#     LEFT JOIN mywms_group_mywms_role gr ON gr.grouplist_id=gu.grouplist_id
#     LEFT JOIN mywms_role_mywms_function rf ON rf.rolelist_id=gr.rolelist_id
#     LEFT JOIN mywms_function f ON rf.functionlist_id=f.id
#    WHERE u.name IN ('wmstest','sbtest','panderson') GROUP BY u.name;
#
# ⚠ WHAT THIS CANNOT SEE.
#   - It probes whatever build DEV is running. `gated` mode is meaningless until the merge has
#     actually deployed; confirming that is separate and is NOT black-box for an authz-only change.
#   - It says nothing about SDR twins or /rest/**. None of the ten has a /rest twin (checked), but
#     "this route is gated" is not "this capability is closed".
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

# NON-EXISTENT sentinels. See the banner above before touching these.
NOID=999999999
NOBATCH=SBDEV3155-NOSUCH

pass=0; fail=0

tok() { curl -s --max-time 20 -X POST "$KC" -d grant_type=password -d client_id=om1 \
        --data-urlencode "username=$1" --data-urlencode "password=$PW" \
        | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))"; }

# probe <label> <token> <path> <want: DENIED|ALLOWED>
#   DENIED  = must be 403 (the gate fired)
#   ALLOWED = must be anything BUT 403 (the request got through authorization)
probe() {
  local label="$1" tokv="$2" path="$3" want="$4"
  local out code size denied
  out=$(mktemp)
  code=$(curl -s -o "$out" -w '%{http_code}' --max-time 45 \
         -H "Authorization: Bearer $tokv" -H "$TEN" -H "$FAC" "$API$path")
  size=$(wc -c < "$out" | tr -d ' ')
  [ "$code" = "403" ] && denied=DENIED || denied=ALLOWED

  if [ "$denied" = "$want" ]; then
    printf '  PASS  %-58s %s -> %s (%s B)\n' "$label" "$code" "$denied" "$size"
    pass=$((pass+1))
  else
    printf '  FAIL  %-58s %s -> %s, want %s (%s B)\n' "$label" "$code" "$denied" "$want" "$size"
    fail=$((fail+1))
  fi
  rm -f "$out"
}

# path list: <label> <path>
paths_club=(
  "clubLine/assignStagingLane   /v3/clubLine/assignStagingLane/$NOID/$NOID"
  "clubLine/unlinkStagingLane   /v3/clubLine/unlinkStagingLane/$NOID"
  "clubLine/activateBatch       /v3/clubLine/activateBatch/$NOID/$NOID"
  "clubLine/runClubLine         /v3/clubLine/runClubLine/$NOBATCH"
)
paths_xfer=(
  "transfers/assignTransferLane    /v3/transfers/assignTransferLane/$NOID/$NOID"
  "transfers/reassignTransferLane  /v3/transfers/reassignTransferLane/$NOID/$NOID"
  "transfers/unlinkTransferLane    /v3/transfers/unlinkTransferLane/$NOID"
  "transfers/activateTransferOrder /v3/transfers/activateTransferOrder/$NOID/$NOID"
  "transfers/runTransfer           /v3/transfers/runTransfer/$NOID"
)
paths_pick=(
  "pickingOrderPosition/fixPickingPosition /v3/pickingOrderPosition/fixPickingPosition/$NOID"
)

run_group() { # <token> <want> <array-name...>
  local tokv="$1" want="$2"; shift 2
  local name row
  for name in "$@"; do
    local -n arr="$name"
    for row in "${arr[@]}"; do
      probe "$(echo "$row" | awk '{print $1}')" "$tokv" "$(echo "$row" | awk '{print $2}')" "$want"
    done
    unset -n arr
  done
}

echo "SBDEV-3155 probe — mode=$MODE  api=$API"
echo

T_DEP=$(tok wmstest); T_DIF=$(tok sbtest); T_ADM=$(tok panderson)
for v in T_DEP:wmstest T_DIF:sbtest T_ADM:panderson; do
  n=${v%%:*}; u=${v##*:}
  [ -n "${!n}" ] || { echo "ABORT: could not get a token for $u — check PW" >&2; exit 3; }
done

if [ "$MODE" = "baseline" ]; then
  WANT_DEP=ALLOWED; WANT_CLUB=ALLOWED; WANT_PICK=ALLOWED
  echo "PRE-FIX expectation: every row ALLOWED (not 403) — this IS the exposure AC-1 asks to record."
else
  WANT_DEP=DENIED;  WANT_CLUB=DENIED;  WANT_PICK=DENIED
  echo "POST-FIX expectation: deprived rows DENIED, entitled rows ALLOWED."
fi
echo

echo "A. wmstest (0 fns) — the deprived subject. Every row must be DENIED post-fix."
run_group "$T_DEP" "$WANT_DEP" paths_club paths_xfer paths_pick
echo

echo "B. sbtest (35 fns) — the DIFFERENTIAL. Lacks CLUB_LINE + PICKING_POSITION, HOLDS TRANSFER_ORDER."
echo "   B1 clubLine + fixPickingPosition (must be denied post-fix):"
run_group "$T_DIF" "$WANT_CLUB" paths_club
run_group "$T_DIF" "$WANT_PICK" paths_pick
echo "   B2 transfers (must stay ALLOWED in BOTH modes — this is what proves the gate is not deny-all):"
run_group "$T_DIF" ALLOWED paths_xfer
echo

echo "C. panderson (80 fns) — entitled CONTROL. ALLOWED in both modes, or the gate is wrong."
run_group "$T_ADM" ALLOWED paths_club paths_xfer paths_pick
echo

echo "Result: $pass pass, $fail fail"
[ "$fail" -eq 0 ]
