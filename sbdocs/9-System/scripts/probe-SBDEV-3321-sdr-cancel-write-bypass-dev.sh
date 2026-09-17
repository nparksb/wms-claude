#!/usr/bin/env bash
# SBDEV-3321 bypass #4 — is the Spring Data REST write path to `state = 800` actually open?
#
#   PW='<dev password>' ./probe-SBDEV-3321-sdr-cancel-write-bypass-dev.sh
#
# RESULT, 2026-09-16, wineco/wsl on wms-api.dev.sbo.li, subject panderson:
#   bypass #4 is CLOSED. PATCH/PUT/DELETE on a REAL stockunit id all answered 405 and the row was
#   byte-identical afterwards (amount 5.0000, version 2, still present after the DELETE).
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# 🔴 READ THIS BEFORE EDITING: THE FIRST VERSION OF THIS SCRIPT PRODUCED THE OPPOSITE VERDICT.
#
# It used deliberately NON-EXISTENT ids, on the reasoning that a 405 is decided at mapping time and
# so needs no real row — which would make the probe incapable of changing anything. That reasoning
# is WRONG for Spring Data REST. SDR resolves the entity FIRST and answers 404 before it ever
# evaluates the method, so a withdrawn verb on a missing id is indistinguishable from a published
# verb on a missing id: BOTH return 404. The script read those 404s as "the verb is published" and
# reported *"VERDICT: bypass #4 is OPEN"* — a confident, clean, wrong answer that contradicted the
# source reading. Measured side by side on the same run:
#
#   PATCH /v3/stockunit/999999999  -> 404   (id absent  — proves NOTHING)
#   PATCH /v3/stockunit/988306832  -> 405   (id present — the real answer)
#
# **The id MUST exist.** Confirm with the GET row below before trusting any verdict.
#
# ⚠ AND THE CONTROL HAS TO DISCRIMINATE, NOT MERELY RESPOND. The original C2 asserted only
# "not 405" for a write-published type. Both C2 and the subjects returned 404, so the control
# passed while the instrument was blind. A control is only a control if it answers DIFFERENTLY
# from the subject when the subject is negative. Here that is the Allow header: a write-published
# type shows write verbs, a withdrawn one shows none.
#
# ⚠ THE WRITES BELOW ARE DELIBERATE SEMANTIC NO-OPS — the PATCH/PUT send the row's CURRENT amount,
# read from the DB first. If a verb turns out to be published, the request succeeds and changes
# nothing. Re-read AMOUNT from the database before each run; a stale value here turns this probe
# into a real inventory write.
set -uo pipefail

API=https://wms-api.dev.sbo.li
KC=https://kc2.dev.sbo.li/realms/wineco/protocol/openid-connect/token
PW="${PW:?set PW to the dev password}"
USER_="${USER_:-panderson}"
TEN='X-Tenant-ID: wineco'
FAC='facility_code: wsl'

# A REAL stockunit on dev_wh01_om1, and its CURRENT amount. Re-derive before each run:
#   SELECT id, amount FROM stockunit ORDER BY id DESC LIMIT 1;
SU_ID="${SU_ID:-988306832}"
SU_AMOUNT="${SU_AMOUNT:-5.0000}"

T=$(curl -s --max-time 20 -X POST "$KC" -d grant_type=password -d client_id=om1 \
      --data-urlencode "username=$USER_" --data-urlencode "password=$PW" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
[ -n "$T" ] || { echo "ABORT: no token for $USER_ — check PW"; exit 3; }
H=(-H "Authorization: Bearer $T" -H "$TEN" -H "$FAC" -H 'Content-Type: application/json')

code()  { curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X "$1" "${H[@]}" ${3:+-d "$3"} "$API$2"; }
allow() { curl -s -D- -o /dev/null --max-time 30 -X OPTIONS "${H[@]}" "$API$1" | tr -d '\r' | sed -n 's/^[Aa]llow: //p'; }

printf '== SBDEV-3321 bypass #4 — SDR write path to state=800 ==\n'
printf '   subject: %s   tenant: wineco/wsl\n\n' "$USER_"

printf -- '-- PRECONDITION: the id must EXIST, or every verdict below is void --\n'
G=$(code GET "/v3/stockunit/$SU_ID" "")
printf '  GET /v3/stockunit/%s -> %s  %s\n\n' "$SU_ID" "$G" \
  "$([ "$G" = 200 ] && echo 'ok — id exists' || echo 'ABORT: pick a live id (see header)')"
[ "$G" = 200 ] || exit 2

# ⚠ The control MUST use the ITEM path (/v3/boxtype/1), not the collection (/v3/boxtype).
# COLLECTION and ITEM exposure are configured separately (withCollectionExposure vs
# withItemExposure), and boxtype's collection advertises HEAD,GET,OPTIONS only — identical to a
# withdrawn type. Using the collection path makes the control indistinguishable from the subject
# and the probe aborts as void. Measured 2026-09-16: /v3/boxtype -> HEAD,GET,OPTIONS but
# /v3/boxtype/1 -> HEAD,DELETE,GET,OPTIONS,PUT.
printf -- '-- CONTROL: Allow must DIFFER between a withdrawn and a published type --\n'
AW=$(allow "/v3/stockunit/$SU_ID"); AP=$(allow "/v3/boxtype/1")
printf '  withdrawn  stockunit -> %s\n' "$AW"
printf '  published  boxtype   -> %s\n' "$AP"
case "$AP" in *PUT*|*POST*|*DELETE*|*PATCH*) printf '  control ok — the instrument can see write verbs\n\n';;
  *) printf '  CONTROL FAILED — cannot see write verbs anywhere; verdicts void\n'; exit 2;; esac

printf -- '-- THE DECISIVE WRITES (semantic no-ops: same amount the row already holds) --\n'
fail=0
for v in PATCH PUT; do
  c=$(code "$v" "/v3/stockunit/$SU_ID" "{\"amount\":$SU_AMOUNT}")
  [ "$c" = 405 ] || fail=1
  printf '  %-6s /v3/stockunit/%s -> %s  %s\n' "$v" "$SU_ID" "$c" \
    "$([ "$c" = 405 ] && echo 'CLOSED (verb withdrawn)' || echo 'OPEN — verb is published')"
done
c=$(code DELETE "/v3/stockunit/$SU_ID" ""); [ "$c" = 405 ] || fail=1
printf '  %-6s /v3/stockunit/%s -> %s  %s\n' DELETE "$SU_ID" "$c" \
  "$([ "$c" = 405 ] && echo 'CLOSED (verb withdrawn)' || echo 'OPEN — verb is published')"

printf '\n'
[ "$fail" = 0 ] \
  && printf 'VERDICT: bypass #4 is CLOSED on dev. Confirm the row is unchanged:\n  SELECT id, amount, version FROM stockunit WHERE id = %s;\n' "$SU_ID" \
  || printf 'VERDICT: bypass #4 is OPEN — a write verb is published. CHECK THE ROW IMMEDIATELY.\n'
