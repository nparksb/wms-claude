#!/usr/bin/env bash
# uat-sdr-metrics.sh [--control]: READ-ONLY reader of the SDR guard's SHADOW counters on UAT (SBDEV-4131 AC-2).
#
# What it can do, and nothing else:
#   GET https://wms-api.uat.sbo.li/api/public/version
#   GET /actuator/metrics/wms2.authz.sdr.{would_deny,unruled,denied,allowed}[?tag=...]   (needs ADMIN / wms_admin)
#   --control: GET /v3 once as the configured user. In SHADOW this records would_deny{domainType=none,function=index},
#              the positive control that proves the counter is live (a 404 meter otherwise just means "never incremented").
# No method other than GET, no other path, no other host. It never writes.
#
# ⚠ The counters carry domainType + function ONLY: no tenant, no user (SdrFunctionGuard). One UAT deployment
#   serves all four tenants, so a non-zero would_deny says THAT a ruled type would be refused somewhere, not
#   for whom. Attributing it needs the "SHADOW: would deny" log lines (tenant in the tenantId MDC field).
#   Counters are JVM-local and reset on every UAT deploy: read before each deploy and sum.
#
# Credentials: ~/.config/wms-dev-probe/uat-credentials, owned by you, mode 600, parsed (never sourced).
# Keys: WMS_UAT_USER, WMS_UAT_PASSWORD, optional WMS_UAT_KEY (default wsl-wineco), WMS_UAT_TENANT (wineco),
# WMS_UAT_FACILITY (wsl). Create it in your OWN terminal, never through Claude (see SKILL.md, Setup):
#   IFS= read -rp 'UAT user: ' U; IFS= read -rsp 'UAT password: ' P; echo
#   ( umask 077; printf 'WMS_UAT_USER=%s\nWMS_UAT_PASSWORD=%s\n' "$U" "$P" > ~/.config/wms-dev-probe/uat-credentials ); unset U P
#
# Output: one TSV line per (meter, domainType, function) appended to $WMS_UAT_READINGS (default
# ~/.cache/wms-dev-probe/uat-sdr-readings.tsv), and printed. Exit 0 ok, 1 HTTP/auth failure, 2 setup.
set +x; set -uo pipefail
. "$(dirname "$0")/env.sh" || exit 2          # helpers (mode_of, mkdir_secure) and $STATE only; dev values unused
HOST=https://wms-api.uat.sbo.li               # the ONLY host this script talks to
UCRED=$HOME/.config/wms-dev-probe/uat-credentials
CONTROL=0
case "$#:${1-}" in 0:) ;; 1:--control) CONTROL=1;; *) echo "usage: uat-sdr-metrics.sh [--control]" >&2; exit 2;; esac

U=""; PW=""; KEY=wsl-wineco; TEN=wineco; FAC=wsl
[ -e "$UCRED" ] || { echo "no $UCRED: create it in your own terminal (see the header of this script)" >&2; exit 2; }
if [ ! -f "$UCRED" ] || [ -L "$UCRED" ] || [ ! -O "$UCRED" ] || [ "$(mode_of "$UCRED")" != 600 ]; then
  echo "refusing: $UCRED must be a regular file you own, mode 600" >&2; exit 2
fi
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}; [ -z "$line" ] && continue; case "$line" in \#*) continue;; esac
  k=${line%%=*}; v=${line#*=}
  case "$k" in
    WMS_UAT_USER) U=$v;; WMS_UAT_PASSWORD) PW=$v;; WMS_UAT_KEY) KEY=$v;; WMS_UAT_TENANT) TEN=$v;; WMS_UAT_FACILITY) FAC=$v;;
    *) echo "warning: ignoring unknown key '$k' in $UCRED" >&2;;
  esac
done < "$UCRED"
[ -n "$U" ] && [ -n "$PW" ] || { echo "WMS_UAT_USER / WMS_UAT_PASSWORD missing in $UCRED" >&2; exit 2; }
for x in "$KEY" "$TEN" "$FAC"; do [[ "$x" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { echo "refusing: odd key/tenant/facility '$x'" >&2; exit 2; }; done

HDR=$(mktemp "$STATE/uathdr.XXXXXX") || exit 2
trap 'rm -f "$HDR"' EXIT

# --- token (same shape as token.sh, but the Keycloak host must be *.uat.sbo.li) ---
CFG=$(curl -s --max-time 10 "$HOST/api/public/authConfig?key=$KEY")
jq -e '.authServerUrl and .realm and .clientId' >/dev/null 2>&1 <<<"$CFG" || { echo "authConfig for '$KEY' failed" >&2; exit 1; }
KC=$(jq -r .authServerUrl <<<"$CFG"); REALM=$(jq -r .realm <<<"$CFG"); CLIENT=$(jq -r .clientId <<<"$CFG")
python3 -I - "$KC" <<'EOF' || { echo "refusing: Keycloak URL '$KC' is not https://<host>.uat.sbo.li" >&2; exit 2; }
import sys, re, urllib.parse
raw = sys.argv[1]; u = urllib.parse.urlsplit(raw); h = u.hostname or ''
ok = raw == raw.strip() and u.scheme == 'https' and u.port in (None, 443) and not u.username and not u.query \
     and not u.fragment and u.path in ('', '/') and re.fullmatch(r'([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)*uat\.sbo\.li', h) is not None
sys.exit(0 if ok else 1)
EOF
[[ "$REALM" =~ ^[A-Za-z0-9_-]+$ ]] && [[ "$CLIENT" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "refusing: odd realm/client" >&2; exit 2; }
RESP=$(printf '%s' "$PW" | curl -s --max-time 15 -X POST "${KC%/}/realms/$REALM/protocol/openid-connect/token" \
  --data-urlencode grant_type=password --data-urlencode "client_id=$CLIENT" \
  --data-urlencode "username=$U" --data-urlencode "password@-")
unset PW
TOK=$(jq -r '.access_token // empty' 2>/dev/null <<<"$RESP"); unset RESP
[ -n "$TOK" ] || { echo "UAT token request failed" >&2; exit 1; }
printf 'Authorization: Bearer %s\n' "$TOK" > "$HDR"; unset TOK

get() {  # $1 = path (fixed set only). Prints body; returns 0 on 200, 1 on 404/other, 2 on transport failure.
  case "$1" in /v3|/actuator/metrics/wms2.authz.sdr.*) ;; *) echo "refusing path $1" >&2; return 2;; esac
  local out code
  out=$(curl -s --max-time 30 -w '\n%{http_code}' -H "@$HDR" -H "X-Tenant-ID: $TEN" -H "facility_code: $FAC" "$HOST$1") || return 2
  code=${out##*$'\n'}; printf '%s\n' "${out%$'\n'*}"
  case "$code" in 200) return 0;; 000) return 2;; *) return 1;; esac
}

ver=$(curl -s --max-time 10 "$HOST/api/public/version" | jq -r '.self.version // "?"' 2>/dev/null)
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUTF=${WMS_UAT_READINGS:-$HOME/.cache/wms-dev-probe/uat-sdr-readings.tsv}
if [ $CONTROL -eq 1 ]; then
  get /v3 >/dev/null; rc=$?
  echo "control: GET /v3 as $U on $TEN/$FAC -> rc=$rc (in SHADOW it should add would_deny{none,index})" >&2
fi
# auth sanity: a meter that must exist proves the token has actuator access (a 403 here = not ADMIN/wms_admin)
probe=$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' -H "@$HDR" -H "X-Tenant-ID: $TEN" -H "facility_code: $FAC" "$HOST/actuator/metrics/jvm.threads.live")
[ "$probe" = 200 ] || { echo "actuator not readable (HTTP $probe): the user needs ADMIN or wms_admin" >&2; exit 1; }

for meter in wms2.authz.sdr.would_deny wms2.authz.sdr.unruled wms2.authz.sdr.denied wms2.authz.sdr.allowed; do
  body=$(get "/actuator/metrics/$meter"); rc=$?
  if [ $rc -ne 0 ]; then
    tag="(absent: never incremented since the last deploy)"; [ $rc -eq 1 ] || tag="(unreachable)"
    printf '%s\t%s\t%s\t-\t-\t0\t%s\n' "$ts" "$ver" "$meter" "$tag" | tee -a "$OUTF"; continue
  fi
  types=$(jq -r '(.availableTags[]? | select(.tag=="domainType") | .values[]) // empty' <<<"$body")
  for dt in $types; do
    [[ "$dt" =~ ^[A-Za-z0-9_.-]+$ ]] || continue
    sub=$(get "/actuator/metrics/$meter?tag=domainType:$dt") || continue
    fns=$(jq -r '[.availableTags[]? | select(.tag=="function") | .values[]] | if length==0 then "-" else .[] end' <<<"$sub")
    for fn in $fns; do
      q="tag=domainType:$dt"; [ "$fn" != "-" ] && { [[ "$fn" =~ ^[A-Za-z0-9_.-]+$ ]] || continue; q="$q&tag=function:$fn"; }
      c=$(get "/actuator/metrics/$meter?$q" | jq -r '.measurements[0].value // "?" | if type=="number" then floor else . end')
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$ver" "$meter" "$dt" "$fn" "$c" | tee -a "$OUTF"
    done
  done
done
