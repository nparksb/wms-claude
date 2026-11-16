#!/usr/bin/env bash
# uat-sdr-metrics.sh [--control]: READ-ONLY reader of the SDR guard's SHADOW counters on UAT (SBDEV-4131 AC-2).
#
# Every request it can make (nothing else, and it never writes to the WMS):
#   GET  https://wms-api.uat.sbo.li/api/public/version and /api/public/authConfig?key=<key>
#   POST https://<host>.uat.sbo.li/realms/<realm>/protocol/openid-connect/token   (Keycloak password grant; host pinned)
#   GET  /actuator/metrics/jvm.threads.live                                      (auth probe: a meter that must exist)
#   GET  /actuator/metrics/wms2.authz.sdr.{would_deny,unruled,denied,allowed,path_collision}
#        [?tag=domainType:<v>[&tag=function:<v>]]                                 (values: [A-Za-z0-9_.-] only)
#   GET  /v3   only with --control: in SHADOW it records would_deny{domainType=none,function=index}. The script
#        reads that count before and after and fails unless it went up: the positive control that the counter is
#        live and the tenant is in SHADOW (a 404 meter otherwise only means "never incremented since deploy").
#
# ⚠ The counters carry domainType + function ONLY: no tenant, no user (SdrFunctionGuard). One UAT deployment
#   serves all four tenants, so a non-zero would_deny says THAT a ruled type would be refused somewhere, not for
#   whom. Attributing it needs the "SHADOW: would deny" log lines (tenant in the tenantId MDC field).
#   Counters are JVM-local and reset on every UAT deploy: read before each deploy and sum.
#
# Credentials: ~/.config/wms-dev-probe/uat-credentials, owned by you, mode 600, parsed (never sourced).
# Keys: WMS_UAT_USER, WMS_UAT_PASSWORD (an ADMIN / wms_admin user), optional WMS_UAT_KEY (default wsl-wineco),
# WMS_UAT_TENANT (wineco), WMS_UAT_FACILITY (wsl). Create it in your OWN terminal, never through Claude:
#   IFS= read -rp 'UAT user: ' U; IFS= read -rsp 'UAT password: ' P; echo
#   ( umask 077; printf 'WMS_UAT_USER=%s\nWMS_UAT_PASSWORD=%s\n' "$U" "$P" > ~/.config/wms-dev-probe/uat-credentials ); unset U P
#
# Output: TSV rows  ts  version  meter  domainType  function  count  [note]  appended to $WMS_UAT_READINGS
# (default ~/.cache/wms-dev-probe/uat-sdr-readings.tsv) and printed. count is a number, or ERR when the read
# failed — a failed read is NEVER written as 0. Only a 404 with an EMPTY body (Spring: meter never incremented)
# is written as 0 with note "absent"; a 404 page from the ingress during a deploy is an ERR.
# Exit: 0 = every read succeeded (and, with --control, would_deny{none,index} went up across the GET /v3);
#       1 = any read/HTTP/auth failure or a failed control; 2 = setup.
set +x; set -uo pipefail
. "$(dirname "$0")/env.sh" || exit 2          # helpers (mode_of, mkdir_secure) and $STATE only; env.sh skips the
                                             # DEV credentials for this script (keyed on its file name)
HOST=https://wms-api.uat.sbo.li               # the ONLY WMS host this script talks to
UCRED=$HOME/.config/wms-dev-probe/uat-credentials
METERS="wms2.authz.sdr.would_deny wms2.authz.sdr.unruled wms2.authz.sdr.denied wms2.authz.sdr.allowed wms2.authz.sdr.path_collision"
CONTROL=0
case "$#:${1-}" in 0:) ;; 1:--control) CONTROL=1;; *) echo "usage: uat-sdr-metrics.sh [--control]" >&2; exit 2;; esac

U=""; PW=""; KEY=wsl-wineco; TEN=wineco; FAC=wsl
[ -e "$UCRED" ] || { echo "no $UCRED: create it in your own terminal (see the header of this script)" >&2; exit 2; }
if [ ! -f "$UCRED" ] || [ -L "$UCRED" ] || [ ! -O "$UCRED" ] || [ "$(mode_of "$UCRED")" != 600 ]; then
  echo "refusing: $UCRED must be a regular file you own, mode 600" >&2; exit 2
fi
n=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n+1)); line=${line%$'\r'}; [ -z "$line" ] && continue; case "$line" in \#*) continue;; esac
  k=${line%%=*}; v=${line#*=}
  case "$k" in
    WMS_UAT_USER) U=$v;; WMS_UAT_PASSWORD) PW=$v;; WMS_UAT_KEY) KEY=$v;; WMS_UAT_TENANT) TEN=$v;; WMS_UAT_FACILITY) FAC=$v;;
    *) echo "warning: ignoring unrecognised line $n in $UCRED (content not shown: it may hold a password)" >&2;;
  esac
done < "$UCRED"
[ -n "$U" ] && [ -n "$PW" ] || { echo "WMS_UAT_USER / WMS_UAT_PASSWORD missing in $UCRED" >&2; exit 2; }
for x in "$KEY" "$TEN" "$FAC"; do [[ "$x" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { echo "refusing: odd key/tenant/facility in $UCRED" >&2; exit 2; }; done
OUTF=${WMS_UAT_READINGS:-$HOME/.cache/wms-dev-probe/uat-sdr-readings.tsv}
[ -d "$(dirname "$OUTF")" ] || { echo "readings dir $(dirname "$OUTF") does not exist" >&2; exit 2; }

HDR=$(mktemp "$STATE/uathdr.XXXXXX") || exit 2
trap 'rm -f "$HDR"' EXIT

# --- token (same shape as token.sh, but the Keycloak host must be *.uat.sbo.li) ---
CFG=$(curl -s --max-time 10 "$HOST/api/public/authConfig?key=$KEY")
jq -e '.authServerUrl and .realm and .clientId' >/dev/null 2>&1 <<<"$CFG" || { echo "UAT authConfig for '$KEY' failed (network, or unknown key)" >&2; exit 1; }
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
TOK=$(jq -r '.access_token // empty' 2>/dev/null <<<"$RESP")
if [ -z "$TOK" ]; then
  echo "UAT token request failed: $(jq -c '{error,error_description}' 2>/dev/null <<<"$RESP" || echo '(no JSON response: network?)')" >&2
  exit 1
fi
unset RESP
printf 'Authorization: Bearer %s\n' "$TOK" > "$HDR"; unset TOK

GET_BODY=""; GET_CODE=""
get() {  # $1 = path. Sets GET_BODY / GET_CODE. Returns 0 on 200; 1 on a 404 with an EMPTY body (Spring's answer for
         # a meter never incremented); 3 on any other HTTP status, including an ingress 404 page; 2 on transport
         # failure; 4 when the path is refused (GET_CODE=refused).
  local p=$1 base q out m
  GET_BODY=""; GET_CODE=refused
  base=${p%%\?*}; q=""; [ "$base" = "$p" ] || q="?${p#*\?}"
  case "$base" in
    /v3|/actuator/metrics/jvm.threads.live) [ -z "$q" ] || { echo "refusing path $p" >&2; return 4; };;
    /actuator/metrics/*)
       m=${base#/actuator/metrics/}
       [[ "$m" =~ ^wms2\.authz\.sdr\.[a-z_]+$ ]] || { echo "refusing path $p" >&2; return 4; }
       case " $METERS " in *" $m "*) ;; *) echo "refusing path $p" >&2; return 4;; esac
       [ -z "$q" ] || [[ "$q" =~ ^\?tag=domainType:[A-Za-z0-9_.-]+(\&tag=function:[A-Za-z0-9_.-]+)?$ ]] \
         || { echo "refusing query $q" >&2; return 4; };;
    *) echo "refusing path $p" >&2; return 4;;
  esac
  GET_CODE=000
  out=$(curl -s --max-time 30 -w '\n%{http_code}' -H "@$HDR" -H "X-Tenant-ID: $TEN" -H "facility_code: $FAC" "$HOST$p") || return 2
  case "$out" in *$'\n'*) GET_CODE=${out##*$'\n'}; GET_BODY=${out%$'\n'*};; *) GET_CODE=$out; GET_BODY="";; esac
  [[ "$GET_CODE" =~ ^[0-9]{3}$ ]] || GET_CODE=000      # no status line at all = transport failure, never a blank code
  case "$GET_CODE" in
    200) return 0;;
    404) [ -z "${GET_BODY//[[:space:]]/}" ] && return 1; GET_CODE="404 with a body (ingress/proxy, not Spring)"; return 3;;
    000) return 2;; *) return 3;;
  esac
}

FAIL=0
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ver=$(curl -s --max-time 10 "$HOST/api/public/version" | jq -r '.self.version // empty' 2>/dev/null); [ -n "$ver" ] || ver="(version unreadable)"
row() { if printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$ver" "$@" | tee -a "$OUTF"; then :; else echo "could not append to $OUTF" >&2; FAIL=1; fi; }
err() { echo "ERROR: $*" >&2; FAIL=1; }

# auth probe before anything is recorded
get /actuator/metrics/jvm.threads.live; rc=$?
case "$rc:$GET_CODE" in
  0:*) ;;
  2:*) echo "UAT unreachable (transport failure)" >&2; exit 1;;
  *:401) echo "actuator answered 401: token rejected (wrong tenant key / X-Tenant-ID?)" >&2; exit 1;;
  *:403) echo "actuator answered 403: the user needs ADMIN or wms_admin" >&2; exit 1;;
  *) echo "actuator probe failed: HTTP $GET_CODE" >&2; exit 1;;
esac
ctl_count() {  # prints would_deny{none,index}: 0 when the meter is absent, nothing when the read failed
  get "/actuator/metrics/wms2.authz.sdr.would_deny?tag=domainType:none&tag=function:index"
  case $? in 0) jq -r '.measurements[0].value // empty | floor' <<<"$GET_BODY" 2>/dev/null;; 1) echo 0;; esac
}
if [ $CONTROL -eq 1 ]; then
  before=$(ctl_count); get /v3; rc=$?; after=$(ctl_count)
  if [ $rc -ne 0 ]; then err "control GET /v3 failed (rc=$rc, HTTP $GET_CODE): the positive control did not fire"
  elif [ -z "$before" ] || [ -z "$after" ]; then err "control: could not read would_deny{none,index} before/after"
  elif [ "$after" -gt "$before" ]; then echo "control ok: would_deny{none,index} $before -> $after (counter is live; tenant $TEN is in SHADOW)" >&2
  else err "control: GET /v3 answered 200 but would_deny{none,index} stayed $before -> $after (tenant $TEN not in SHADOW, or counter not live)"; fi
fi

for meter in $METERS; do
  get "/actuator/metrics/$meter"; rc=$?
  case $rc in
    0) ;;
    1) row "$meter" - - 0 "absent (404: never incremented since the last deploy)"; continue;;
    *) row "$meter" - - ERR "read failed (HTTP $GET_CODE)"; err "$meter: HTTP $GET_CODE"; continue;;
  esac
  types=$(jq -r '.availableTags[]? | select(.tag=="domainType") | .values[] | "v:" + .' <<<"$GET_BODY") \
    || { row "$meter" - - ERR "unparseable response"; err "$meter: unparseable"; continue; }
  if [ -z "$types" ]; then
    c=$(jq -r '.measurements[0].value // empty | floor' <<<"$GET_BODY" 2>/dev/null)
    if [ -n "$c" ]; then row "$meter" - - "$c" "no domainType tag"; else row "$meter" - - ERR "no count"; err "$meter: no count"; fi
    continue
  fi
  while IFS= read -r dt; do
    dt=${dt#v:}
    [[ "$dt" =~ ^[A-Za-z0-9_.-]+$ ]] || { row "$meter" "(odd value)" - ERR "domainType not readable safely"; err "$meter: odd domainType"; continue; }
    get "/actuator/metrics/$meter?tag=domainType:$dt"; rc=$?
    [ $rc -eq 0 ] || { row "$meter" "$dt" - ERR "drill-down failed (HTTP $GET_CODE)"; err "$meter/$dt: HTTP $GET_CODE"; continue; }
    fns=$(jq -r '.availableTags[]? | select(.tag=="function") | .values[] | "v:" + .' <<<"$GET_BODY") \
      || { row "$meter" "$dt" - ERR "unparseable response"; err "$meter/$dt: unparseable"; continue; }
    if [ -z "$fns" ]; then
      c=$(jq -r '.measurements[0].value // empty | floor' <<<"$GET_BODY" 2>/dev/null)
      if [ -n "$c" ]; then row "$meter" "$dt" - "$c"; else row "$meter" "$dt" - ERR "no count"; err "$meter/$dt: no count"; fi
      continue
    fi
    while IFS= read -r fn; do
      fn=${fn#v:}
      [[ "$fn" =~ ^[A-Za-z0-9_.-]+$ ]] || { row "$meter" "$dt" "(odd value)" ERR "function not readable safely"; err "$meter/$dt: odd function"; continue; }
      get "/actuator/metrics/$meter?tag=domainType:$dt&tag=function:$fn"; rc=$?
      c=""; [ $rc -eq 0 ] && c=$(jq -r '.measurements[0].value // empty | floor' <<<"$GET_BODY" 2>/dev/null)
      if [ -n "$c" ]; then row "$meter" "$dt" "$fn" "$c"; else row "$meter" "$dt" "$fn" ERR "read failed (HTTP $GET_CODE)"; err "$meter/$dt/$fn: HTTP $GET_CODE"; fi
    done <<<"$fns"
  done <<<"$types"
done
exit $FAIL
