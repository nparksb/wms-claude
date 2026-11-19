#!/usr/bin/env bash
# uat-sdr-metrics.sh [--control]: READ-ONLY reader of the SDR guard's SHADOW counters on UAT (SBDEV-4131 AC-2).
#
# Every request it can make (nothing else, and it never writes to the WMS):
#   GET  https://wms-api.uat.sbo.li/api/public/version and /api/public/authConfig?key=<key>
#   POST https://<host>.uat.sbo.li/realms/<realm>/protocol/openid-connect/token   (Keycloak password grant; host pinned)
#   GET  /actuator/prometheus   the whole scrape, parsed locally. UAT exposes ONLY health, info, prometheus and
#        tenantpool (measured 2026-11-19 on v0.0.45): /actuator/metrics answers Spring's JSON 404 there, which is
#        why this script no longer reads it.
#   GET  /v3   only with --control: in SHADOW it records would_deny{domainType=none,function=index}. The script
#        scrapes before and after and passes only if BOTH scrapes come from the same JVM (equal
#        process_start_time_seconds: a second replica or a restart fails it) AND that count rose by exactly 1.
#        That proves the counter is live, and is CONSISTENT with tenant $TEN being in SHADOW (OFF counts nothing,
#        ENFORCE_RULED answers 403). It cannot prove it: the counter has no tenant tag, so another SHADOW tenant's
#        /v3 landing in the same instant while ours counted nothing would look identical. A delta of 2: rerun.
#        A passed control is written to the TSV as a "control" row (+1), so probe hits can be subtracted later.
#   Every curl call starts with -q, so a ~/.curlrc (-v, --trace, -L) can neither log the token nor follow a redirect.
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
# failed — a failed read is NEVER written as 0. A meter is written as 0 with note "absent" only when the scrape
# is proven to be a whole wms2-api scrape (HTTP 200, ends in a newline, carries
# application_ready_time_seconds{main_application_class="net.aim_ai.wms.StartApplication"} plus
# process_start/uptime) and NO line in it mentions wms2_authz_sdr without parsing: Micrometer creates a counter
# on its first increment. Residual blind spot: a build that never registers a meter looks the same as one that
# never incremented it. A body cut short by the server yet still well-formed is not detectable here (curl
# itself fails a short transfer).
# Counts are written from the FIRST scrape, taken before any --control GET, so this run's own probe never shows;
# the would_deny{none,index} row is still marked as the probe series, since earlier --control runs added to it.
# Labels other than domainType/function (denied: controller, reason; path_collision: path, kept, shadowed;
# mode_read_failed: exception) go into the note as key=value; an empty label value is written as (empty).
# The first row (meter "jvm", count "-") says when the JVM (re)started: the window these counts cover. If UAT
# ever runs more than one replica, every reading is per-pod; the control then fails on the start-time check.
# Exit: 0 = every read succeeded (and, with --control, the control passed); 1 = any read/HTTP/auth failure or
#       a failed control (rows from the first scrape are still written); 2 = setup (python3 >= 3.6 is required).
set +x; set -uo pipefail
. "$(dirname "$0")/env.sh" || exit 2          # helpers (mode_of, mkdir_secure) and $STATE only; env.sh skips the
                                             # DEV credentials for this script (keyed on its file name)
command -v python3 >/dev/null 2>&1 && python3 -I -c 'import sys; sys.exit(sys.version_info < (3, 6))' 2>/dev/null \
  || { echo "python3 >= 3.6 is required (parses the Keycloak URL and the scrape)" >&2; exit 2; }
HOST=https://wms-api.uat.sbo.li               # the ONLY WMS host this script talks to
UCRED=$HOME/.config/wms-dev-probe/uat-credentials
METERS="would_deny unruled denied allowed path_collision mode_read_failed"   # wms2_authz_sdr_<m>_total in the scrape
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
CFG=$(curl -q -s --max-time 10 "$HOST/api/public/authConfig?key=$KEY")
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
RESP=$(printf '%s' "$PW" | curl -q -s --max-time 15 -X POST "${KC%/}/realms/$REALM/protocol/openid-connect/token" \
  --data-urlencode grant_type=password --data-urlencode "client_id=$CLIENT" \
  --data-urlencode "username=$U" --data-urlencode "password@-")
unset PW
TOK=$(printf '%s' "$RESP" | jq -r '.access_token // empty' 2>/dev/null)
if [ -z "$TOK" ]; then
  echo "UAT token request failed: $(printf '%s' "$RESP" | jq -c '{error,error_description}' 2>/dev/null || echo '(no JSON response: network?)')" >&2
  exit 1
fi
unset RESP
printf 'Authorization: Bearer %s\n' "$TOK" > "$HDR"; unset TOK

GET_BODY=""; GET_CODE=""
get() {  # $1 = path, one of a fixed two. Sets GET_BODY / GET_CODE. Returns 0 on 200; 3 on any other HTTP status;
         # 2 on transport failure; 4 when the path is refused (GET_CODE=refused).
  local p=$1 out
  GET_BODY=""; GET_CODE=refused
  case "$p" in /v3|/actuator/prometheus) ;; *) echo "refusing path $p" >&2; return 4;; esac
  GET_CODE=000
  out=$(curl -q -s --max-time 30 -w '\n%{http_code}' -H "@$HDR" -H "X-Tenant-ID: $TEN" -H "facility_code: $FAC" "$HOST$p") || return 2
  case "$out" in *$'\n'*) GET_CODE=${out##*$'\n'}; GET_BODY=${out%$'\n'*};; *) GET_CODE=$out; GET_BODY="";; esac
  [[ "$GET_CODE" =~ ^[0-9]{3}$ ]] || GET_CODE=000      # no status line at all = transport failure, never a blank code
  case "$GET_CODE" in 200) return 0;; 000) return 2;; *) return 3;; esac
}

# parse <mode> [meters...]: reads a scrape on stdin; never crashes on input (every failure is a printed line).
#   rows    -> META <start_epoch> <uptime>, then ROW meter domainType function count note  |  ERR meter|- message
#   control -> OK <would_deny{none,index} count> <start_epoch>
#   either  -> BAD <reason> alone when the body is not provably a whole wms2-api scrape
# A label value reaches a ROW only if it matches [A-Za-z0-9_./{}-]+ (empty -> "(empty)"); anything else is an ERR.
parse() {
  python3 -I -c '
import sys, re, math
mode, meters = sys.argv[1], sys.argv[2:]
if mode == "control": meters = ["would_deny"]   # the control reads exactly one meter
try:
    text = sys.stdin.buffer.read().decode("utf-8", "replace")
    SAFE = re.compile(r"[A-Za-z0-9_./{}-]+\Z")
    LINE = re.compile(r"wms2_authz_sdr_([a-z_]+?)_total(?:\{(.*)\})?[ \t]+(\S+)(?:[ \t]+-?\d+)?\Z")
    LABEL = re.compile(r"\s*([A-Za-z_][A-Za-z0-9_]*)=\"((?:[^\"\\]|\\.)*)\"\s*(?:,|\Z)")
    def gauge(name):
        m = re.search(r"^" + name + r"(?:\{[^}\n]*\})?[ \t]+(\S+)[ \t]*$", text, re.M)
        try: v = float(m.group(1)) if m else None
        except ValueError: v = None
        return v if v is not None and math.isfinite(v) and v >= 0 else None
    start, up = gauge("process_start_time_seconds"), gauge("process_uptime_seconds")
    app = re.search(r"^application_ready_time_seconds\{[^}\n]*main_application_class=\"net\.aim_ai\.wms\.StartApplication\"", text, re.M)
    samples = [l for l in text.splitlines() if l and not l.startswith("#")]
    last = re.match(r"[A-Za-z_:][A-Za-z0-9_:]*", samples[-1]) if samples else None
    # Micrometer writes metric families in name order, so a body cut before or inside the SDR block ends on a name
    # that sorts before it. If that ordering ever changes this fails CLOSED (nothing recorded), never open.
    if not last or last.group(0) <= "wms2_authz_sdr_~":
        print("BAD\tscrape looks cut short: its last sample (" + (last.group(0) if last else "none") +
              ") does not sort after the wms2_authz_sdr block"); sys.exit(0)
    if not text.endswith("\n") or not app or start is None or up is None:
        print("BAD\tnot a whole wms2-api scrape (needs a final newline, application_ready_time_seconds for "
              "net.aim_ai.wms.StartApplication, process_start_time_seconds and process_uptime_seconds)")
        sys.exit(0)
    series = []                       # ("ROW", meter, labels, count) | ("ERR", meter-or-None, message)
    for ln in text.splitlines():
        if "wms2_authz_sdr" not in ln or ln.lstrip().startswith("#"): continue
        m = LINE.match(ln)            # anchored at column 0: an indented sample line is an ERR, never skipped
        if not m:
            g = re.search(r"wms2_authz_sdr_([a-z_]+?)_total", ln)
            if g and g.group(1) not in meters: continue      # a meter this script does not track: not its problem
            mt = g.group(1) if g else None
            series.append(("ERR", mt, (mt or "a wms2_authz_sdr line") + ": unparseable series line")); continue
        meter, raw, val = m.group(1), m.group(2) or "", m.group(3)
        if meter not in meters: continue
        labels, pos, why = {}, 0, None
        while pos < len(raw):
            lm = LABEL.match(raw, pos)
            if not lm: why = "unparseable labels"; break
            k, v = lm.group(1), lm.group(2)
            if k in labels: why = "duplicate label " + k; break
            if v == "": v = "(empty)"
            elif not SAFE.match(v): why = "label " + k + " has a value that is not readable safely"; break
            labels[k] = v; pos = lm.end()
        count = None
        if why is None:
            iv = re.fullmatch(r"(\d+)(?:\.0*)?", val)  # Micrometer writes "3.0": take the integer part exactly
            if iv: count = int(iv.group(1))
            else:
                try: f = float(val)
                except ValueError: f = None
                if f is not None and math.isfinite(f) and f >= 0: count = int(f)
            if count is None: why = "count is not a finite non-negative number"
        if why: series.append(("ERR", meter, meter + ": " + why)); continue
        series.append(("ROW", meter, labels, count))
    if mode == "control":
        if any(s[0] == "ERR" and s[1] in (None, "would_deny") for s in series):
            print("BAD\twould_deny is not provably readable in this scrape"); sys.exit(0)
        n = sum(s[3] for s in series if s[0] == "ROW" and s[1] == "would_deny"
                and s[2].get("domainType") == "none" and s[2].get("function") == "index")
        print("OK\t%d\t%s" % (n, repr(start))); sys.exit(0)
    print("META\t%d\t%d" % (int(start), int(up)))
    seen = set()
    for s in series:
        if s[0] == "ERR":             # an errored meter is SEEN: it must never fall through to "absent, 0"
            seen.add(s[1]); print("ERR\t%s\t%s" % (s[1] or "(unattributed)", s[2])); continue
        _, meter, labels, count = s
        if meter not in meters: continue
        seen.add(meter)
        note = " ".join(k + "=" + v for k, v in sorted(labels.items()) if k not in ("domainType", "function"))
        if meter == "would_deny" and labels.get("domainType") == "none" and labels.get("function") == "index":
            note = (note + " " if note else "") + "GET /v3 index hits from any user, plus the --control probes of this script (see the control rows)"
        print("\t".join(["ROW", meter, labels.get("domainType", "-"), labels.get("function", "-"), str(count), note]))
    for meter in meters:
        if meter in seen: continue
        if None in seen:              # an unattributable bad line might be this meter: never claim 0
            print("ERR\t%s\t%s: not provably absent (the scrape held an unparseable wms2_authz_sdr line)" % (meter, meter))
        else:
            print("\t".join(["ROW", meter, "-", "-", "0", "absent: no series in this scrape (never incremented since the JVM started, or not registered by this build)"]))
except Exception as e:                # fail closed with a reason instead of a traceback
    print("BAD\tparser error: " + type(e).__name__)
' "$@"
}

FAIL=0; CTL_OK=0
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ver=$(curl -q -s --max-time 10 "$HOST/api/public/version" | jq -r '.self.version // empty' 2>/dev/null); [[ "$ver" =~ ^[A-Za-z0-9._+-]{1,40}$ ]] || ver="(version unreadable)"
row() { if printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$ver" "$@" | tee -a "$OUTF"; then :; else echo "could not append to $OUTF" >&2; FAIL=1; fi; }
err() { echo "ERROR: $*" >&2; FAIL=1; }

# scrape 1: the auth probe AND the source of every recorded count. Nothing is recorded until it is proven real.
get /actuator/prometheus; rc=$?
case "$rc:$GET_CODE" in
  0:*) ;;
  2:*) echo "UAT unreachable (transport failure)" >&2; exit 1;;
  *:401) echo "actuator answered 401: token rejected (wrong tenant key / X-Tenant-ID?)" >&2; exit 1;;
  *:403) echo "actuator answered 403: the token carries no ADMIN / wms_admin role (any client under resource_access counts)" >&2; exit 1;;
  *:404) echo "actuator answered 404: /actuator/prometheus is not exposed on this deploy" >&2; exit 1;;
  *) echo "actuator scrape failed: HTTP $GET_CODE" >&2; exit 1;;
esac
BODY1=$GET_BODY
OUT=$(printf '%s' "$BODY1" | parse rows $METERS)
case "$OUT" in META$'\t'*) ;; BAD$'\t'*) echo "ERROR: $(printf '%s\n' "$OUT" | cut -f2) (nothing recorded)" >&2; exit 1;;
  *) echo "ERROR: parser gave no usable output (nothing recorded)" >&2; exit 1;; esac

if [ $CONTROL -eq 1 ]; then
  c1=$(printf '%s' "$BODY1" | parse control)
  case "$c1" in OK*) get /v3; rc=$?; v3code=$GET_CODE;; *) rc=5; v3code="not sent";; esac
  if [ $rc -eq 5 ]; then err "control: the before-count is not readable ($(printf '%s\n' "$c1" | cut -f2)); GET /v3 not sent"
  elif [ $rc -ne 0 ]; then err "control: GET /v3 failed (rc=$rc, HTTP $v3code): the positive control did not fire"
  elif ! get /actuator/prometheus; then err "control: the after-scrape failed (HTTP $GET_CODE)"
  else
    c2=$(printf '%s' "$GET_BODY" | parse control)
    case "$c1:$c2" in
      OK*:OK*)
        b=$(printf '%s' "$c1" | cut -f2); s1=$(printf '%s' "$c1" | cut -f3)
        a=$(printf '%s' "$c2" | cut -f2); s2=$(printf '%s' "$c2" | cut -f3)
        if [ "$s1" != "$s2" ]; then err "control: the two scrapes came from different JVMs (start $s1 vs $s2): a restart, or more than one replica"
        elif [ $((a - b)) -eq 1 ]; then CTL_OK=1; echo "control ok: would_deny{none,index} $b -> $a in one JVM (counter is live; consistent with tenant $TEN in SHADOW, which the untagged counter cannot prove)" >&2
        elif [ $((a - b)) -eq 0 ]; then err "control: GET /v3 answered 200 but would_deny{none,index} stayed $b (tenant $TEN not in SHADOW, or counter not live)"
        else err "control: would_deny{none,index} moved $b -> $a, not by exactly 1 (a concurrent /v3 from another tenant?): rerun"; fi;;
      *) err "control: before/after count not readable ($(printf '%s\n' "$c1" | cut -f1)/$(printf '%s\n' "$c2" | cut -f1))";;
    esac
  fi
  if [ "$CTL_OK" = 1 ]; then row control none index 1 "this run's --control probe: +1 to would_deny{none,index} AFTER the counts below"
  else row control - - ERR "the --control check failed (see stderr); the counts below are still valid"; fi
fi

while IFS=$'\t' read -r kind a b c d e; do
  case "$kind" in
    META) jst=$(python3 -I -c 'import sys,datetime as d; print(d.datetime.fromtimestamp(int(sys.argv[1]), d.timezone.utc).isoformat())' "$a" 2>/dev/null)
          row jvm - - - "JVM (re)started ${jst:-at epoch $a} (uptime $b s): the window these counts cover";;
    ROW)  row "wms2.authz.sdr.$a" "$b" "$c" "$d" "$e";;
    ERR)  row "wms2.authz.sdr.$a" - - ERR "$b"; err "$b";;
    *)    row - - - ERR "parser emitted an unknown line"; err "parser emitted an unknown line";;
  esac
done <<<"$OUT"
exit $FAIL
