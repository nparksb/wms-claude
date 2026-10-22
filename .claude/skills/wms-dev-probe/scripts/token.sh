#!/usr/bin/env bash
# token.sh: fetch a Keycloak access token for the dev WMS v2 API and cache it (mode 600, per user).
# Prints only the user, groups and expiry. The password goes to curl on stdin; the token never
# touches argv (it is handed to curl as a header FILE by api.sh).
set +x; set -uo pipefail
. "$(dirname "$0")/env.sh" || exit 2
[ -n "$WMS_DEV_USER" ] && [ -n "$WMS_DEV_PASSWORD" ] || {
  echo "no credentials: see .claude/skills/wms-dev-probe/SKILL.md, Setup (run it in your own terminal)" >&2; exit 2; }
CFG=$(curl -s --max-time 10 "$WMS_DEV_HOST/api/public/authConfig?key=$WMS_DEV_KEY")
jq -e '.authServerUrl and .realm and .clientId' >/dev/null 2>&1 <<<"$CFG" \
  || { echo "authConfig for '$WMS_DEV_KEY' failed: $(head -c 200 <<<"$CFG")" >&2; exit 1; }
KC=$(jq -r .authServerUrl <<<"$CFG"); REALM=$(jq -r .realm <<<"$CFG"); CLIENT=$(jq -r .clientId <<<"$CFG")
# exact: https, hostname is dev.sbo.li or a subdomain of it, default port, no path tricks
python3 -I - "$KC" <<'EOF' || { echo "refusing: Keycloak URL '$KC' is not https://<host>.dev.sbo.li" >&2; exit 2; }
import sys, urllib.parse
u = urllib.parse.urlsplit(sys.argv[1])
h = (u.hostname or '')
import re
raw = sys.argv[1]
ok = raw == raw.strip() and u.scheme == 'https' and u.port in (None, 443) and not u.username and not u.query and not u.fragment \
     and re.fullmatch(r'([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)*dev\.sbo\.li', h) is not None and u.path in ('', '/')
sys.exit(0 if ok else 1)
EOF
[[ "$REALM" =~ ^[A-Za-z0-9_-]+$ ]] && [[ "$CLIENT" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "refusing: odd realm/client in authConfig" >&2; exit 2; }
RESP=$(printf '%s' "$WMS_DEV_PASSWORD" | curl -s --max-time 15 -X POST "${KC%/}/realms/$REALM/protocol/openid-connect/token" \
  --data-urlencode grant_type=password --data-urlencode "client_id=$CLIENT" \
  --data-urlencode "username=$WMS_DEV_USER" --data-urlencode "password@-")
TOK=$(jq -r '.access_token // empty' 2>/dev/null <<<"$RESP")
[ -n "$TOK" ] || { echo "token request failed: $(jq -c '{error,error_description}' 2>/dev/null <<<"$RESP" || head -c 200 <<<"$RESP")" >&2; exit 1; }
T1=$(mktemp "$STATE/tok.XXXXXX") && T2=$(mktemp "$STATE/hdr.XXXXXX") \
  && printf '%s' "$TOK" > "$T1" && printf 'Authorization: Bearer %s\n' "$TOK" > "$T2" \
  && mv -f "$T1" "$TOKEN_FILE" && mv -f "$T2" "$HDR_FILE" \
  || { rm -f "${T1:-}" "${T2:-}"; echo "could not write token" >&2; exit 1; }
python3 -I -c '
import sys,json,base64,time
p=open(sys.argv[1]).read().split(".")[1]; p+="="*(-len(p)%4); c=json.loads(base64.urlsafe_b64decode(p))
print("token ok: user=%s groups=%s expires_in=%ds" % (c.get("preferred_username"), c.get("groups"), c["exp"]-time.time()))' "$TOKEN_FILE"
