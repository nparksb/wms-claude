#!/usr/bin/env bash
# SBDEV-3373 read-only dev probe: the System Properties admin surfaces still load, and the two deleted keys are gone.
#   PW=<dev password> ./probe-wms2-sbdev3373-dead-sysprops-dev.sh   (read-only; passed 2026-10-07)
set -uo pipefail
API=https://wms-api.dev.sbo.li/v3
KC=https://kc2.dev.sbo.li/realms/wineco/protocol/openid-connect/token
T=$(curl -s --max-time 20 -X POST "$KC" -d grant_type=password -d client_id=om1 \
      --data-urlencode "username=panderson" --data-urlencode "password=$PW" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
[ -n "$T" ] || { echo "ABORT: no token for panderson"; exit 3; }
H=(-H "Authorization: Bearer $T" -H "X-Tenant-ID: wineco" -H "facility_code: wsl")
get() { curl -s --max-time 30 -o "$2" -w '%{http_code}' "${H[@]}" "$API$1"; }
keys() { python3 - "$1" <<'PY'
import sys,json
d=json.load(open(sys.argv[1])); out=[]
def walk(x):
    if isinstance(x,dict):
        if 'syskey' in x: out.append(x['syskey'])
        for v in x.values(): walk(v)
    elif isinstance(x,list):
        for v in x: walk(v)
walk(d); print("\n".join(out))
PY
}
DEAD='^(WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED|WEBSERVICE_BEHAVIOUR)$'
for path in "/sysprop/search/findByGroupname?groupName=Backend" "/sysprop?size=1000"; do
  code=$(get "$path" /tmp/p3373.json); keys /tmp/p3373.json > /tmp/p3373.keys 2>/dev/null
  n=$(wc -l < /tmp/p3373.keys); dead=$(grep -cE "$DEAD" /tmp/p3373.keys); ctl=$(grep -c '^WEBSERVICE_ORDER_BATCH_UPDATE_PRIORITY_ACTIVATED$' /tmp/p3373.keys); web=$(grep -c '^WEBSERVICE_' /tmp/p3373.keys)
  echo "GET $path -> HTTP $code | rows=$n | WEBSERVICE_*=$web | dead keys=$dead | control PRIORITY_ACTIVATED=$ctl"
done
rm -f /tmp/p3373.json /tmp/p3373.keys
