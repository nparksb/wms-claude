#!/usr/bin/env bash
#
# SBDEV-3371 — release the two held WineCo v1 orders by consolidating club-face stock.
#
#   Ackley Brands   order 062100-000004 (ME101413)        — SKU 2290074, needs one unit >= 6
#   Zerolink/VinoS. order 062126-000001 (96934210193:807) — SKU 42000,   needs one unit >= 12
#
# WHY THIS WORKS. Both orders are held by the SBDEV-2512 guard in ReleaseOrderJobService: a
# non-partitionable position must be fillable from ONE stock unit. Aggregate stock is exactly
# sufficient (6 of 6, 12 of 12) but spread over several unit loads, so no single unit covers the
# line. Merging the residue onto one unit load per SKU satisfies the guard; the order-release cron
# (every minute) then releases both orders on its own. No code change, no restart.
#
# WHAT IT DOES. Three calls to POST /v3/stockUnit/transferStock with isTransferExistingContainer
# =true — the same service path the web UI's Move Stock uses (StockunitService.transferStock ->
# StockunitBusinessService.transferStockToUnitLoad). That writes the stockrecord pair
# (recordRemoval + recordCreation), sends the emptied source stock unit and its unit load to
# Nirwana, and bumps @Version. It never touches the database directly.
#
# EXPECTED SIDE EFFECTS, so nothing is a surprise:
#   * Unit loads UL354466, UL296350, UL259126 end up empty and are sent to Nirwana; their labels
#     disappear from Club01/Club02. The emptied STOCK UNITS are not deleted — sendStockUnitToNirvana
#     reparents them to the Nirwana unit load and sets entity_lock = 405, so the rows still exist.
#   * On release the job calls ManageOrderService.customerOrderReleaseForPicking, which POSTs to
#     WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING —
#     https://api-oms.wineco.sbo.li/services/call/readytopick on this database. Two orders are
#     announced to the LIVE production OMS within ~2 minutes. That part cannot be taken back.
#
# SAFETY. Every leg is guarded on both sides: the source amount must be exactly what is expected
# before the transfer, and the destination must be exactly what is expected after it. A leg that has
# already been applied is detected and SKIPPED, so the script is safe to re-run and safe to resume
# after a partial failure.
#
# Usage:
#   API=<v1 api base url> ./fix-SBDEV-3371-consolidate-club-stock.sh                # verify only
#   API=... KC_USER=... KC_PASS=... ./fix-SBDEV-3371-consolidate-club-stock.sh --apply
#
# Runbook: sbdocs/2-Areas/runbooks/sbdev-3371-ackley-zerolink-consolidation.md
#
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Connection settings — the four that must be right.
#
# API has NO default on purpose. It is the one value no evidence in the repo or the database
# establishes, and a wrong-but-reachable v1 host would accept these ids (UL###### is a house-wide
# label format and stock unit ids are per-database) and move somebody else's stock while printing
# OK. Confirm it with whoever owns the deploy. The probe below is the backstop, not the primary
# control: it checks that this host's database holds the exact stock shape we measured.
#
# KC / REALM / CLIENT defaults are READ FROM PRODUCTION los_sysprop on wh01_om1 (2026-09-16):
#   KEYCLOAK_SERVER_URL = https://kc.om1.komatik.co/auth
#   KEYCLOAK_REALM      = komatik
#   KEYCLOAK_CLIENT     = om1-api/<secret>     <- confidential client: id BEFORE the slash,
#                                                 client secret AFTER it
# Do NOT use kc.dev.sbo.li / realm spk / client om1 — those are the DEV values that
# application.properties commits.
# ─────────────────────────────────────────────────────────────────────────────
API="${API:-}"
KC="${KC:-https://kc.om1.komatik.co/auth}"
REALM="${REALM:-komatik}"
CLIENT="${CLIENT:-om1-api}"
CLIENT_SECRET="${CLIENT_SECRET:-}"   # read it out of los_sysprop KEYCLOAK_CLIENT, after the slash
KC_USER="${KC_USER:-}"
KC_PASS="${KC_PASS:-}"

COMMENT="SBDEV-3371 consolidate club face so the held order can release"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-180}"  # generous: transferStockToUnitLoad does several writes plus
                                     # up to 5 optimistic-lock retries with backoff

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

# ─────────────────────────────────────────────────────────────────────────────
# The plan. Per leg:
#   src_su | qty | src_ul | dst_ul | dst_su | dst_before | dst_after | note
# Zerolink runs first: one call, smallest blast radius, and it exercises the identical code branch
# (same unit-load type, same merge path) so it genuinely proves the recipe before Ackley's two.
# ─────────────────────────────────────────────────────────────────────────────
PLAN=(
  "34966260|2|UL354466|UL196620|672162417|10|12|Zerolink SKU 42000: 10 + 2 -> one unit of 12 (Club02)"
  "946694784|2|UL296350|UL296352|946694786|3|5|Ackley SKU 2290074: 3 + 2 -> 5 (Club01), still short"
  "833881128|1|UL259126|UL296352|946694786|5|6|Ackley SKU 2290074: 5 + 1 -> one unit of 6 (Club01)"
)

echo "SBDEV-3371 — consolidate club-face stock (WineCo v1 PRODUCTION)"
echo "API   : ${API:-<unset>}"
echo "KC    : $KC  realm=$REALM  client=$CLIENT"
echo "Mode  : $([[ $APPLY == 1 ]] && echo 'APPLY — this mutates production inventory' || echo 'VERIFY ONLY — nothing will change')"
echo
printf '%-11s %4s  %-9s %-9s %-11s %s\n' "SOURCE SU" "QTY" "FROM UL" "TO UL" "DEST SU" "EFFECT"
for row in "${PLAN[@]}"; do
  IFS='|' read -r su qty from to dst before after note <<<"$row"
  printf '%-11s %4s  %-9s %-9s %-11s %s\n' "$su" "$qty" "$from" "$to" "$dst" "$note"
done
echo

[[ -n "$API" ]] || { echo "ERROR: set API to the WineCo v1 API base URL. There is no safe default — see the header." >&2; exit 1; }
[[ -n "$KC_USER" && -n "$KC_PASS" ]] || { echo "ERROR: set KC_USER and KC_PASS." >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# HTTP helper. Deliberately NOT `curl -f`:
#   * /v3/stockUnit/transferStock answers HTTP 200 on FAILURE, with {"errors":[...]} — the
#     controller catches BusinessException/FacadeException/Exception and returns 200. A status-code
#     check reports success on a refused transfer.
#   * but a 401/404/500/timeout/DNS failure is NOT 200, and with `-f` under `set -e` the script
#     would die inside the command substitution before any handler could explain the state.
# So: capture status and body separately, never let curl fail the script, and judge explicitly.
# ─────────────────────────────────────────────────────────────────────────────
HTTP_STATUS=""; HTTP_BODY=""
http() {                       # http GET <url> | http POST <url> <json>
  local method="$1" url="$2" data="${3:-}" raw rc
  set +e
  if [[ "$method" == "POST" ]]; then
    raw=$(curl -sS --max-time "$HTTP_TIMEOUT" -w $'\n%{http_code}' -X POST "$url" \
            -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' -d "$data" 2>&1)
  else
    raw=$(curl -sS --max-time "$HTTP_TIMEOUT" -w $'\n%{http_code}' "$url" \
            -H "Authorization: Bearer $AT" 2>&1)
  fi
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then HTTP_STATUS="000"; HTTP_BODY="curl exit $rc: $raw"; return 0; fi
  HTTP_STATUS="${raw##*$'\n'}"; HTTP_BODY="${raw%$'\n'*}"
}

# Returns the current amount of stock unit $1, or MISSING, or ERROR:<reason>.
# /v3/moveStock/selectSource/<stockUnitId> returns every stock unit on that unit load; we pick ours
# out by id. A stock unit already sent to Nirwana still resolves, with amount 0.
su_amount() {
  local su="$1"
  http GET "$API/v3/moveStock/selectSource/$su"
  if [[ "$HTTP_STATUS" != "200" ]]; then echo "ERROR:http $HTTP_STATUS ${HTTP_BODY:0:200}"; return 0; fi
  printf '%s' "$HTTP_BODY" | python3 -c '
import json, sys
want = int(sys.argv[1])
try:
    doc = json.load(sys.stdin)
except Exception as e:
    print("ERROR:unparseable %s" % e); raise SystemExit
if isinstance(doc, dict) and doc.get("errors"):
    print("ERROR:%s" % json.dumps(doc["errors"])[:200]); raise SystemExit
found = []
def walk(n):
    if isinstance(n, dict):
        if n.get("id") == want and "amount" in n:
            found.append(n["amount"])
        for v in n.values(): walk(v)
    elif isinstance(n, list):
        for v in n: walk(v)
walk(doc)
print(float(found[0]) if found else "MISSING")
' "$su"
}

# ─────────────────────────────────────────────────────────────────────────────
# Token. om1-api is a CONFIDENTIAL client (los_sysprop stores it as id/secret), so the password
# grant needs client_secret. Without it Keycloak answers invalid_client, not a token.
# ─────────────────────────────────────────────────────────────────────────────
tok_args=(--data-urlencode grant_type=password --data-urlencode "client_id=$CLIENT"
          --data-urlencode "username=$KC_USER" --data-urlencode "password=$KC_PASS")
[[ -n "$CLIENT_SECRET" ]] && tok_args+=(--data-urlencode "client_secret=$CLIENT_SECRET")

AT=$(curl -sS --max-time 30 -X POST "$KC/realms/$REALM/protocol/openid-connect/token" \
      -H 'Content-Type: application/x-www-form-urlencoded' "${tok_args[@]}" \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
if "access_token" not in d: sys.exit("keycloak: %s" % json.dumps(d)[:300])
print(d["access_token"])')
[[ -n "$AT" ]] || { echo "ERROR: no access token." >&2; exit 1; }
echo "token acquired"
echo

# ─────────────────────────────────────────────────────────────────────────────
# Positive identification of the target environment.
#
# NOT a Java-version check: this is Spring Boot 2.3.7 with no build-info and no git-commit-id
# plugin, so /actuator/info returns {} — a version guard here would be dead code that always
# warns and trains the operator to click through it.
#
# Instead assert the exact stock shape we measured on 2026-09-16. Only WineCo v1 production has
# stock unit 946694786 holding 3 and 672162417 holding 10. If this host's database disagrees,
# it is either the wrong host or the state has moved — both must stop the run.
# ─────────────────────────────────────────────────────────────────────────────
echo "identifying the target database..."
ack=$(su_amount 946694786)   # Ackley destination, Club01
zer=$(su_amount 672162417)   # Zerolink destination, Club02
printf '  stock unit 946694786 = %s   stock unit 672162417 = %s\n' "$ack" "$zer"

# Accept the untouched shape OR any prefix of this plan already being applied, so a resume after a
# partial run is not mistaken for the wrong host. The per-leg checks below do the fine-grained work.
#   0 legs (3,10) · leg1 (3,12) · legs1-2 (5,12) · all three (6,12)
ident_ok=0
for pair in "3|10" "3|12" "5|12" "6|12"; do
  IFS='|' read -r a z <<<"$pair"
  if [[ ( "$ack" == "$a" || "$ack" == "$a.0" ) && ( "$zer" == "$z" || "$zer" == "$z.0" ) ]]; then
    ident_ok=1; legs_done="$pair"; break
  fi
done
if [[ $ident_ok != 1 ]]; then
  cat >&2 <<'EOF'

STOPPING — this is not the database the plan was built against, or the stock has moved since.

Expected stock units 946694786 / 672162417 to read 3/10 (nothing applied), 3/12, 5/12 or 6/12
(this plan partly or fully applied). They read something else, which means either API points at a
different deployment, or someone has picked or moved this stock.

Do NOT pass --apply. Re-run the Step 1 pre-flight SQL in the runbook and re-derive the plan from
what it returns.
EOF
  exit 1
fi
case "$legs_done" in
  "3|10") echo "target confirmed — nothing applied yet" ;;
  "6|12") echo "target confirmed — this plan is ALREADY FULLY APPLIED; nothing left to do" ;;
  *)      echo "target confirmed — partially applied, will resume" ;;
esac
echo

if [[ $APPLY == 0 ]]; then
  echo "Verify-only run. Re-run with --apply to perform the three transfers."
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Apply. Each leg is idempotent: source already drained + destination already credited = skip.
# ─────────────────────────────────────────────────────────────────────────────
leg=0
for row in "${PLAN[@]}"; do
  leg=$((leg+1))
  IFS='|' read -r su qty from to dst before after note <<<"$row"
  echo "leg $leg: move $qty from stock unit $su ($from) into $to"
  echo "        $note"

  src_now=$(su_amount "$su"); dst_now=$(su_amount "$dst")
  echo "        source=$src_now  destination=$dst_now"

  if [[ "$src_now" == "0.0" || "$src_now" == "0" ]] && [[ "$dst_now" == "$after" || "$dst_now" == "$after.0" ]]; then
    echo "        already applied — skipping"; echo; continue
  fi
  if [[ "$src_now" != "$qty" && "$src_now" != "$qty.0" ]] || [[ "$dst_now" != "$before" && "$dst_now" != "$before.0" ]]; then
    echo "        STOPPING — expected source=$qty destination=$before. Something changed." >&2
    echo "        Nothing in this leg has run. Re-run the Step 1 pre-flight SQL before doing anything else." >&2
    exit 1
  fi

  http POST "$API/v3/stockUnit/transferStock" \
    "{\"id\":$su,\"amountToTransfer\":$qty,\"isTransferExistingContainer\":true,\"labelId\":\"$to\",\"printLabel\":false,\"comment\":\"$COMMENT\"}"

  if [[ "$HTTP_STATUS" == "200" && "$(printf '%s' "$HTTP_BODY" | tr -d '[:space:]')" == "true" ]]; then
    echo "        OK"
  elif [[ "$HTTP_STATUS" == "200" ]]; then
    echo "        REFUSED (HTTP 200 + errors) — server said: $HTTP_BODY" >&2
    echo "        Nothing moved in this leg. Earlier legs are committed and safe to leave:" >&2
    echo "        a partial merge just leaves the order held, exactly as it is today." >&2
    echo "        Re-running this script is safe — applied legs are detected and skipped." >&2
    exit 1
  else
    echo "        UNKNOWN OUTCOME — HTTP $HTTP_STATUS: ${HTTP_BODY:0:400}" >&2
    echo "        A timeout or a dropped connection does NOT roll the server transaction back," >&2
    echo "        so this leg may or may not have committed. Do not guess: re-run the Step 1" >&2
    echo "        pre-flight SQL to see the real state, then re-run this script — it will skip" >&2
    echo "        whatever actually landed." >&2
    exit 1
  fi
  echo
done

cat <<'EOF'
All three legs are applied.

The order-release cron runs every minute. Within ~2 minutes both orders should leave state 50,
and the release will POST both to the production OMS (readytopick). Confirm with the Step 3 SQL:

  customerorder 34956804 and 34963469  -> state 200 (ASSIGNED, shown as "Released"), not 50
  positions     34956807 and 34963470  -> state 200, not 55

Still at 50 after five minutes? Re-run the Step 1 pre-flight SQL FIRST — it tells you whether the
consolidation actually holds — then read the runbook's "if it does not release" section.
EOF
