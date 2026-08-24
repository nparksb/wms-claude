#!/usr/bin/env bash
# curl-matrix-SBDEV-3003-slice2.sh
#
# The plan's §5 manual curl matrix for SBDEV-3003 Slice 2, as a runnable script.
#   sbdocs/1-Projects/wms2/plan/SBDEV-3003-slice2-transfer-stock-idempotency.md §5
#
# WHY THIS EXISTS AS A SCRIPT: nothing in either PR booted a filter chain, read a counter from a live
# registry, or touched a database — it is all unit-level. Only this matrix covers Spring Security
# filter ORDERING and the real chain. Rows 4, 6, 7, 8 and 9 are the ones that catch the catastrophic
# designs; rows 1-3 only prove the happy path. Row 8 is what would have surfaced review finding F2.
#
# ⚠ THIS SCRIPT MOVES REAL STOCK. Rows 1, 2, 3, 4 and 9 each perform a genuine transfer against
#   whatever tenant you point it at. Run it on DEV. Row 4 deliberately creates a SECOND unit load —
#   that is the assertion, not a bug.
#
# ─── What you must supply ────────────────────────────────────────────────────────────────────────
#   API        v2 API base, e.g. https://wms-api.dev.sbo.li      (NOT wms-api.wineco.dev.sbo.li —
#                                                                 that host is v1/Java 8)
#   TOKEN      a bearer token for the TENANT'S OWN Keycloak realm. A token from the v1 realm
#              (`spk`, client `om1`) is rejected: the per-tenant JwtDecoder will not accept it.
#   TENANT     X-Tenant-ID   value
#   FACILITY   facility_code value
#   STOCK_ID   stockUnit.id to move — needs amount >= 2 so a PARTIAL transfer is possible. A partial
#              transfer decrements the source IN PLACE under the same PK, which is what makes the
#              repeat in row 4 send a byte-identical body. A FULL transfer deletes the source and the
#              repeat 404s instead, which tests nothing.
#   DEST       destination container label for the 'existing container' path
#
# Optional: AMOUNT (default 1), UNRELATED_PATH (row 7).
#
# ─── Verifying the code under test is actually deployed ──────────────────────────────────────────
# /actuator/info exposes only JVM info here, not app.version, so it CANNOT tell you which commit is
# live. Use row 8's header shape instead — it is the discriminator, and needs no credentials:
#   * NOT deployed : 401 WITH `www-authenticate: Bearer`  (Spring's BearerTokenAuthenticationEntryPoint
#                    — the filter was never in scope, so AuthorizationFilter refused the request)
#   * DEPLOYED     : 401 with NO www-authenticate header  (IdempotencyFilter's own G-f gate, which
#                    just sets the status and returns)
# Row 0 below checks this and ABORTS if the fix is not live, because every other row would otherwise
# return a plausible, honest-looking result that means only "not deployed yet".
#
# ─── DB checks ───────────────────────────────────────────────────────────────────────────────────
# The unit-load counts are NOT asserted here — they need the tenant DB (MCP `wms2-*`). The script
# prints the exact query and the expected delta after each mutating row. Run it, or the row proves
# nothing: a 200 tells you the request was accepted, not that exactly one UL was created.
set -uo pipefail

API="${API:-}"; TOKEN="${TOKEN:-}"; TENANT="${TENANT:-}"; FACILITY="${FACILITY:-}"
STOCK_ID="${STOCK_ID:-}"; DEST="${DEST:-}"; AMOUNT="${AMOUNT:-1}"
UNRELATED_PATH="${UNRELATED_PATH:-/v3/stockUnit/transferStockToUnitLoad}"
PATH_ENROLLED="/v3/stockUnit/transferStock"

die() { printf '\n\033[31mABORT\033[0m %s\n' "$1" >&2; exit 1; }
[ -n "$API" ] || die "set API (e.g. https://wms-api.dev.sbo.li)"

body() {  # $1 = amount
    printf '{"id":%s,"amountToTransfer":%s,"printLabel":false,"locationName":"Clearing","labelId":"%s","isTransferExistingContainer":true,"comment":"SBDEV-3003 slice2 matrix"}' \
        "$STOCK_ID" "$1" "$DEST"
}

# Prints "<http_code>|<single-line body>"
call() {  # $1 = nonce ("" = omit header), $2 = json body, $3 = path, $4 = "noauth" to omit the token
    local nonce=$1 payload=$2 path=$3 mode=${4:-auth}
    local -a h=(-H 'Content-Type: application/json')
    [ "$mode" = "auth" ] && h+=(-H "Authorization: Bearer $TOKEN")
    [ -n "$TENANT" ]   && h+=(-H "X-Tenant-ID: $TENANT")
    [ -n "$FACILITY" ] && h+=(-H "facility_code: $FACILITY")
    [ -n "$nonce" ]    && h+=(-H "Idempotency-Key: $nonce")
    curl -s -m 40 -o /tmp/.m_body -w '%{http_code}' -X POST "$API$path" "${h[@]}" -d "$payload"
    printf '|'; tr -d '\n' < /tmp/.m_body | head -c 400
}

hdrs() {  # like call() but returns headers only
    local nonce=$1 payload=$2 path=$3 mode=${4:-auth}
    local -a h=(-H 'Content-Type: application/json')
    [ "$mode" = "auth" ] && h+=(-H "Authorization: Bearer $TOKEN")
    [ -n "$TENANT" ]   && h+=(-H "X-Tenant-ID: $TENANT")
    [ -n "$FACILITY" ] && h+=(-H "facility_code: $FACILITY")
    [ -n "$nonce" ]    && h+=(-H "Idempotency-Key: $nonce")
    curl -s -m 40 -D - -o /dev/null -X POST "$API$path" "${h[@]}" -d "$payload"
}

row() { printf '\n\033[1m── Row %s — %s\033[0m\n' "$1" "$2"; }
got() { printf '   got: %s\n' "$1"; }
want(){ printf '   \033[36mwant:\033[0m %s\n' "$1"; }
dbq() { printf '   \033[33mDB:\033[0m %s\n' "$1"; }

N="SBDEV3003-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"

echo "SBDEV-3003 Slice 2 — §5 curl matrix"
echo "  API=$API   path=$PATH_ENROLLED"
echo "  nonce base=$N"

# ── Row 0: is the fix actually deployed? ─────────────────────────────────────────────────────────
row 0 "deployment discriminator (no credentials needed)"
H=$(hdrs "$N-probe" "$(body 1)" "$PATH_ENROLLED" noauth)
CODE=$(printf '%s' "$H" | awk 'NR==1{print $2}')
if printf '%s' "$H" | grep -qi '^www-authenticate:'; then
    got "401 WITH www-authenticate  -> filter NOT in scope"
    die "the Slice 2 fix is NOT deployed on this host. Every row below would return a plausible
      result that means only 'not deployed'. Merge + let the develop image redeploy, then re-run."
fi
[ "$CODE" = "401" ] || die "expected 401 from the unauthenticated probe, got $CODE"
got "401, no www-authenticate  -> IdempotencyFilter's own G-f gate is live"

for v in TOKEN TENANT FACILITY STOCK_ID DEST; do
    [ -n "${!v}" ] || die "set $v to run rows 1-9 (row 0 passed, so the fix IS deployed)"
done

# ── Row 8 first: it is the highest-value row and mutates nothing ─────────────────────────────────
row 8 "no Authorization header -> clean 401, NOT a 500, and no landlord-DB write"
got "$(call "$N-r8" "$(body 1)" "$PATH_ENROLLED" noauth)"
want "401. A 500 here means the request reached tryClaim and routed to the LANDLORD db (42P01).
        This is the row that would have surfaced review finding F2."

row 7 "an unrelated /v3 POST is unaffected — allow-list, not a /v3 prefix"
got "$(call "$N-r7" '{}' "$UNRELATED_PATH")"
want "whatever that endpoint normally returns (404/400/200) — NOT 409, and no dedupe row written."
dbq  "SELECT count(*) FROM rest_idempotency WHERE idempotency_key = '$N-r7';  -- expect 0"

row 6 "no Idempotency-Key on the enrolled path -> proceeds UNDEDUPED, no auto-derived key"
got "$(call "" "$(body $AMOUNT)" "$PATH_ENROLLED")"
want "200 and the move happens. Then: NO new row, and in particular no 64-char sha256 key."
dbq  "SELECT idempotency_key FROM rest_idempotency WHERE request_path = '$PATH_ENROLLED'
        AND created_at > now() - interval '2 min';  -- expect NO 64-hex key"

row 1 "single transfer, nonce N1 -> 200 and exactly ONE new unit load"
dbq  "BEFORE: SELECT count(*) FROM unitload;   -- record this"
got "$(call "$N-1" "$(body $AMOUNT)" "$PATH_ENROLLED")"
want "200"
dbq  "AFTER : SELECT count(*) FROM unitload;   -- expect +1"

row 3 "nonce N1 AGAIN, sequentially -> replayed 2xx, still only ONE unit load"
got "$(call "$N-1" "$(body $AMOUNT)" "$PATH_ENROLLED")"
want "the SAME 2xx body as row 1, replayed from cache."
dbq  "SELECT count(*) FROM unitload;  -- expect UNCHANGED from row 1"

row 2 "nonce N2 twice CONCURRENTLY -> one 200 + one 409 in-flight, ONE unit load"
( call "$N-2" "$(body $AMOUNT)" "$PATH_ENROLLED" > /tmp/.m_a ) &
( call "$N-2" "$(body $AMOUNT)" "$PATH_ENROLLED" > /tmp/.m_b ) &
wait
got "A: $(cat /tmp/.m_a)"; got "B: $(cat /tmp/.m_b)"
want "one 200, one 409 whose body carries \"idempotency-in-flight\" (NOT key-conflict)."
dbq  "SELECT count(*) FROM unitload;  -- expect exactly +1 for this row"

row 5 "nonce N2, DIFFERENT body -> 409 idempotency-key-conflict"
got "$(call "$N-2" "$(body $((AMOUNT + 1)))" "$PATH_ENROLLED")"
want "409 with \"idempotency-key-conflict\" — a DIFFERENT error string from row 2's."

row 4 "*** nonce N3, byte-identical body -> 200 and a SECOND unit load ***"
got "$(call "$N-3" "$(body $AMOUNT)" "$PATH_ENROLLED")"
want "200, and a NEW unit load. THIS IS THE ROW THAT JUSTIFIES THE WHOLE DESIGN: it proves a
        deliberate repeat move still goes through. If this replays, auto-derive leaked in and the
        fix is silently DROPPING real moves — worse than the bug."
dbq  "SELECT count(*) FROM unitload;  -- expect +1 AGAIN"

row 9 "a FAILING move under nonce N4, then retry after the cause clears -> the retry EXECUTES"
echo "   (needs a genuinely failing destination — lock one, or point DEST at a locked container)"
got "$(call "$N-4" '{"id":999999999,"amountToTransfer":1,"printLabel":false,"locationName":"Clearing","labelId":"DOES-NOT-EXIST","isTransferExistingContainer":true}' "$PATH_ENROLLED")"
want "200 carrying an \"errors\" body (that is how this controller reports failure). Then G-e:"
dbq  "SELECT count(*) FROM rest_idempotency WHERE idempotency_key = '$N-4';  -- expect 0.
        The claim row MUST have been dropped. If it is 1, the failure was cached as a success and
        the operator's retry will replay the failure forever once the blocker clears."

printf '\n\033[1m── Counter (G-d)\033[0m\n'
echo "   curl -s $API/actuator/prometheus | grep wms_idempotency_duplicate_transfer"
echo "   expect: path=\"$PATH_ENROLLED\" with outcome=\"replayed\" (row 3) and \"in_flight\" (row 2)."
echo "   Micrometer does not register a counter until its first increment, so ABSENT before row 2/3"
echo "   is expected and is NOT evidence of a defect. Also confirm no meter carries a junk path"
echo "   label — review finding F1 bounded that tag to the enrolled path plus 'other'."

printf '\n\033[1mRows the matrix cannot cover\033[0m\n'
echo " · CORS preflight for Idempotency-Key, per environment. It is a non-safelisted request header"
echo "   so it REQUIRES preflight approval; allowed-headers=* admits it today but is env-overridable"
echo "   (SBDEV-2632 happened exactly that way). Neither curl nor the DevTools Network panel"
echo "   reliably verifies CORS handling in this repo — only JS reading the response in a browser."
echo " · Handheld QA, including a device with no secure-context crypto (plain HTTP)."
echo " · The residual: a caller who DOES hold wms_user but sends NO tenant headers still routes to"
echo "   landlord for a 500. Add that as a row when you have a second token."
