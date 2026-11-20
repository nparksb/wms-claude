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
#        Every --control run writes a "control" row (see "--control rows" below), so probe hits can be subtracted.
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
# process_start/uptime), EVERY line in it is a well-formed sample or HELP/TYPE comment (else nothing is recorded),
# and NO line in it names a tracked meter without parsing. That means: a tracked name
# anywhere but a sample line's own column-0 name or inside a parsed label value is an ERR; a "#" line naming one
# must be exactly "# HELP <name> ..." or "# TYPE <name> counter" (else a sample may be joined to it: ERR), and a
# meter so declared with no parsed sample is an ERR; a series that appears twice is an ERR (no copy is counted),
# and a meter with an ERR that cannot name its series has none of its series counted;
# lines of other metrics are skipped, and so are untracked wms2_authz_sdr_* meters, except one whose name starts
# with a tracked meter's name, which is an ERR for that meter. Each meter gets at most one ERR row.
# Micrometer creates a counter on its first increment. Residual blind spot: a build that never registers a meter
# looks the same as one that never incremented it. A body cut short yet still well-formed is caught by its last
# sample: Micrometer writes families in name order and the wms2_cron_* gauges sort after the SDR block, so a whole
# scrape ends past it.
# Counts are written from the FIRST scrape, taken before any --control GET, so this run's own probe never shows;
# the would_deny{none,index} row is still marked as the probe series, since earlier --control runs added to it.
# Labels other than domainType/function (denied: controller, reason; path_collision: path, kept, shadowed;
# mode_read_failed: exception) go into the note as key=value; an empty label value is written as (empty).
# The first row (meter "jvm", count "-") says when the JVM (re)started: the window these counts cover. If UAT
# ever runs more than one replica, every reading is per-pod; the control then fails on the start-time check.
# Exit: 0 = every counter read succeeded (and, with --control, the control passed). The version is best effort:
#       an unreadable one is written as "(version unreadable)" and does not fail the run.
#       1 = any counter read/HTTP/auth failure or a failed control (rows from the first scrape are still written);
#       2 = setup (python3 >= 3.6 and jq are required).
# --control rows: "control none index 1" when GET /v3 answered 200 (it counts in SHADOW even when the check then
#       fails), except "control none index 0" when both scrapes, from one JVM, prove it added nothing;
#       "control none index ERR" when /v3 was sent but its outcome is unknown (it may have counted);
#       "control - - ERR" when /v3 was never sent. An interrupt (INT/TERM/HUP) after /v3 was sent still writes
#       "control none index ERR" (exit 130/143/129). One that lands while the control row is being written is
#       held until every row is written, then exits with that same code. Any other signal there (SIGKILL, or one
#       this script does not trap, such as SIGQUIT or SIGUSR1) leaves no control row.
# Rows go to the TSV FIRST, then to stdout; SIGPIPE is ignored, so a closed or vanished stdout reader cannot
# cost a TSV row (it only loses the printed copy).
set +x; set -uo pipefail
trap '' PIPE                                  # a reader that goes away must never kill the run before a TSV row lands
. "$(dirname "$0")/env.sh" || exit 2          # helpers (mode_of, mkdir_secure) and $STATE only; env.sh skips the
                                             # DEV credentials for this script (keyed on its file name)
command -v python3 >/dev/null 2>&1 && python3 -I -c 'import sys; sys.exit(sys.version_info < (3, 6))' 2>/dev/null \
  || { echo "python3 >= 3.6 is required (parses the Keycloak URL and the scrape)" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required (reads the Keycloak config and token)" >&2; exit 2; }
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
  local acc="Accept: */*"
  [ "$p" = /actuator/prometheus ] && acc="Accept: text/plain;version=0.0.4"   # the format parse() reads, not a default
  out=$(curl -q -s --max-time 30 -w '\n%{http_code}' -H "@$HDR" -H "$acc" -H "X-Tenant-ID: $TEN" -H "facility_code: $FAC" \
    "$HOST$p") || return 2
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
    NAME = re.compile(r"[A-Za-z_:][A-Za-z0-9_:]*")
    LINE = re.compile(r"[A-Za-z_:][A-Za-z0-9_:]*(?:\{(.*)\})?[ \t]+(\S+)(?:[ \t]+-?\d+)?\Z")
    LABEL = re.compile(r"\s*([A-Za-z_][A-Za-z0-9_]*)=\"((?:[^\"\\]|\\.)*)\"\s*(?:,|\Z)")
    def gauge(name):
        m = re.search(r"^" + name + r"(?:\{[^}\n]*\})?[ \t]+(\S+)[ \t]*$", text, re.M)
        try: v = float(m.group(1)) if m else None
        except ValueError: v = None
        return v if v is not None and math.isfinite(v) and v >= 0 else None
    start, up = gauge("process_start_time_seconds"), gauge("process_uptime_seconds")
    app = re.search(r"^application_ready_time_seconds\{[^}\n]*main_application_class=\"net\.aim_ai\.wms\.StartApplication\"", text, re.M)
    samples = [l for l in text.split("\n") if l and not l.startswith("#")]
    last = NAME.match(samples[-1]) if samples else None
    # Micrometer writes metric families in name order, so a body cut before or inside the SDR block ends on a name
    # that sorts before it. Families sort by BASE name, so the sample suffix is stripped first (wms2_authz_total is
    # family wms2_authz, which sorts BEFORE the block). If that ordering ever changes this fails CLOSED.
    fam = re.sub(r"_(total|info|count|sum|bucket|created)\Z", "", last.group(0)) if last else ""
    if not fam or fam <= "wms2_authz_sdr_~":
        print("BAD\tscrape looks cut short: its last sample (" + (last.group(0) if last else "none") +
              ") does not sort after the wms2_authz_sdr block (or no metric sorting after it is registered any more)"); sys.exit(0)
    if not text.endswith("\n") or not app or start is None or up is None:
        print("BAD\tnot a whole wms2-api scrape (needs a final newline, application_ready_time_seconds for "
              "net.aim_ai.wms.StartApplication, process_start_time_seconds and process_uptime_seconds)")
        sys.exit(0)
    def wellformed(ln):               # one exposition line: a HELP/TYPE comment, or name{labels} value [timestamp]
        if ln.startswith("#"): return re.fullmatch(r"# (HELP|TYPE) [A-Za-z_:][A-Za-z0-9_:]*( .*)?", ln) is not None
        g = LINE.match(ln)
        if not g: return False
        raw, q = g.group(1) or "", 0
        while q < len(raw):
            lq = LABEL.match(raw, q)
            if not lq: return False
            q = lq.end()
        try: float(g.group(2))
        except ValueError: return False
        return True
    badl = [i for i, l in enumerate(text.split("\n")[:-1], 1) if l and not wellformed(l)]
    if badl:
        print("BAD\tnot a well-formed scrape: line " + str(badl[0]) + " is neither a sample nor a HELP/TYPE comment" +
              (" (and %d more)" % (len(badl) - 1) if len(badl) > 1 else "")); sys.exit(0)
    series = []                       # ("ROW", meter, labels, count) | ("ERR", meter-or-None, message)
    P = "wms2_authz_sdr_"
    TRK = dict((x, P + x + "_total") for x in meters)
    def stray(ln):                    # tracked meters named in ln anywhere but its own column-0 name or a label value
        hits = [(h.start(), x) for x, full in TRK.items() for h in re.finditer(re.escape(full), ln)]
        if not hits: return []
        spans, m0 = [], LINE.match(ln)
        if m0 and m0.group(1) is not None:
            base, raw0, q0 = m0.start(1), m0.group(1), 0
            while q0 < len(raw0):
                lq = LABEL.match(raw0, q0)
                if not lq: spans = []; break
                spans.append((base + lq.start(2), base + lq.end(2))); q0 = lq.end()
        out = set()
        for i, x in hits:
            if i == 0: continue           # the column-0 name is judged by the main loop (exact, near, or ERR)
            if any(a <= i and i + len(TRK[x]) <= b for a, b in spans): continue
            out.add(x)
        return sorted(out)
    declared = set()                  # tracked meters named in a HELP/TYPE line: each must yield a ROW or an ERR
    for ln in text.split("\n"):
        if "wms2_authz_sdr" not in ln: continue
        if ln.lstrip().startswith("#"):   # a sample joined to its HELP/TYPE line must not vanish into the comment
            named = [x for x, full in TRK.items() if full in ln]
            declared.update(named)
            c = re.fullmatch(r"# (HELP|TYPE) (\S+)(.*)", ln)
            total = sum(ln.count(full) for full in TRK.values())
            for x in named:
                if not c or c.group(2) != TRK[x] or total != 1 or (c.group(1) == "TYPE" and c.group(3) != " counter"):
                    series.append(("ERR", x, x + ": a HELP/TYPE line naming it is malformed (a sample may be joined to it)"))
            continue
        for x in stray(ln):           # a corrupted/joined/prefixed tracked name: never let that meter read "absent"
            series.append(("ERR", x, x + ": its series name appears in a line outside a parseable name or label value"))
        nm = NAME.match(ln)           # anchored at column 0: an indented sample line is an ERR, never skipped
        if not nm:
            series.append(("ERR", None, "a wms2_authz_sdr line: no readable metric name at column 0")); continue
        name = nm.group(0)
        if not name.startswith(P): continue                  # another metric; the text sits in one of its labels
        rest = name[len(P):]
        meter = next((x for x in meters if rest == x + "_total"), None)
        if meter is None:
            near = next((x for x in meters if rest.startswith(x)), None)
            if near: series.append(("ERR", near, near + ": unexpected series name " + name))
            continue                                         # else a meter this script does not track
        m = LINE.match(ln)
        if not m:
            series.append(("ERR", meter, meter + ": unparseable series line")); continue
        raw, val = m.group(1) or "", m.group(2)
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
                if f is not None and math.isfinite(f) and f >= 0 and f.is_integer(): count = int(f)
            if count is None: why = "count is not a finite non-negative whole number"
        if why and count is None and why.startswith("count"):  # labels parsed: keep the key, so no copy is counted
            key = (meter, tuple(sorted(labels.items())))
            series.append(("ERR", meter, meter + ": series {" + ",".join(a + "=" + b for a, b in key[1]) + "}: " + why, key))
            continue
        if why: series.append(("ERR", meter, meter + ": " + why)); continue
        series.append(("ROW", meter, labels, count))
    hit = set(s[1] for s in series)
    for x in sorted(declared - hit):
        series.append(("ERR", x, x + ": named in a HELP/TYPE line but no sample of it parsed"))
    if any(s[0] == "ERR" and s[1] is None for s in series):
        print("BAD\tthe scrape holds a wms2_authz_sdr line this parser cannot attribute to a meter"); sys.exit(0)
    cnt, bad, badm = {}, set(), set() # a series that appears more than once: EVERY copy becomes one ERR, none a count
    for s in series:
        if s[0] == "ROW": k = (s[1], tuple(sorted(s[2].items()))); cnt[k] = cnt.get(k, 0) + 1
        elif len(s) > 3: bad.add(s[3])    # a copy whose count failed: its ERR already names the series
        else: badm.add(s[1])          # an ERR that cannot name its series might duplicate any of them: no row counts
    deduped, done = [], set()
    for s in series:
        if s[0] == "ROW":
            k = (s[1], tuple(sorted(s[2].items())))
            if k in bad or s[1] in badm: continue
            if cnt[k] > 1:
                if k not in done:
                    done.add(k)
                    deduped.append(("ERR", s[1], s[1] + ": series {" + ",".join(a + "=" + b for a, b in k[1]) +
                                    "} appears " + str(cnt[k]) + " times"))
                continue
        deduped.append(s)
    series = deduped
    if mode == "control":
        if any(s[0] == "ERR" and s[1] == "would_deny" for s in series):
            print("BAD\twould_deny is not provably readable in this scrape"); sys.exit(0)
        n = sum(s[3] for s in series if s[0] == "ROW" and s[1] == "would_deny"
                and s[2].get("domainType") == "none" and s[2].get("function") == "index")
        print("OK\t%d\t%s" % (n, repr(start))); sys.exit(0)
    print("META\t%d\t%d" % (int(start), int(up)))
    seen, nerr = set(), {}
    for s in series:
        if s[0] == "ERR": nerr[s[1]] = nerr.get(s[1], 0) + 1
    for s in series:
        if s[0] == "ERR":             # an errored meter is SEEN: it must never fall through to "absent, 0"
            if s[1] in seen and nerr.get(s[1], 0) == 0: continue   # one ERR row per meter: the first, with a tally
            seen.add(s[1]); more = nerr[s[1]] - 1; nerr[s[1]] = 0
            print("ERR\t%s\t%s" % (s[1], s[2] + (" (and %d more problem(s) with this meter)" % more if more else ""))); continue
        _, meter, labels, count = s
        if meter not in meters: continue
        seen.add(meter)
        note = " ".join(k + "=" + v for k, v in sorted(labels.items()) if k not in ("domainType", "function"))
        if meter == "would_deny" and labels.get("domainType") == "none" and labels.get("function") == "index":
            note = (note + " " if note else "") + "GET /v3 index hits from any user, plus the --control probes of this script (see the control rows)"
        print("\t".join(["ROW", meter, labels.get("domainType", "-"), labels.get("function", "-"), str(count), note]))
    for meter in meters:
        if meter in seen: continue
        print("\t".join(["ROW", meter, "-", "-", "0", "absent: no series in this scrape (never incremented since the JVM started, or not registered by this build)"]))
except Exception as e:                # fail closed with a reason instead of a traceback
    print("BAD\tparser error: " + type(e).__name__)
' "$@"
}

FAIL=0; CTL_OK=0; WFAIL=0   # WFAIL: a row could not be appended to the TSV
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ver=$(curl -q -s --max-time 10 "$HOST/api/public/version" | jq -r '.self.version // empty' 2>/dev/null); [[ "$ver" =~ ^[A-Za-z0-9._+-]{1,40}$ ]] || ver="(version unreadable)"
row() {  # the TSV first (the record), then stdout best effort (the copy)
  local l; printf -v l '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$ts" "$ver" "$@"   # no $( ) fork: a child would not inherit a held trap
  printf '%s\n' "$l" >> "$OUTF" || { echo "ERROR: could not append to $OUTF" >&2; FAIL=1; WFAIL=1; }
  printf '%s\n' "$l" 2>/dev/null || true
}
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

ctl_interrupted() {  # $1 = exit code. Armed only between GET /v3 and the control row.
  trap '' INT TERM HUP
  row control none index ERR "interrupted after GET /v3 was sent: it may have added 1 to would_deny{none,index}; this run wrote no counts"
  exit "$1"
}
PEND=       # an exit code held from a signal that landed during the control row (see the header)
if [ $CONTROL -eq 1 ]; then
  c1=$(printf '%s' "$BODY1" | parse control)
  SENT=no    # no | 200 (counted if $TEN is in SHADOW) | zero (200, proven to add nothing) | unknown (may have counted)
  case "$c1" in OK*)   # from here an interrupt must still leave a control row (SIGKILL cannot be caught)
      trap 'ctl_interrupted 130' INT; trap 'ctl_interrupted 143' TERM; trap 'ctl_interrupted 129' HUP
      get /v3; rc=$?; v3code=$GET_CODE; if [ $rc -eq 0 ]; then SENT=200; else SENT=unknown; fi;;
    *) rc=5; v3code="not sent";; esac
  if [ $rc -eq 5 ]; then err "control: the before-count is not readable ($(printf '%s\n' "$c1" | cut -f2)); GET /v3 not sent"
  elif [ $rc -ne 0 ]; then err "control: GET /v3 did not answer 200 (rc=$rc, HTTP $v3code): the check cannot run, and the request may still have been counted"
  elif ! get /actuator/prometheus; then err "control: the after-scrape failed (HTTP $GET_CODE)"
  else
    c2=$(printf '%s' "$GET_BODY" | parse control)
    case "$c1:$c2" in
      OK*:OK*)
        b=$(printf '%s' "$c1" | cut -f2); s1=$(printf '%s' "$c1" | cut -f3)
        a=$(printf '%s' "$c2" | cut -f2); s2=$(printf '%s' "$c2" | cut -f3)
        d=$(python3 -I -c 'import sys; print(int(sys.argv[2]) - int(sys.argv[1]))' "$b" "$a" 2>/dev/null)  # exact: no 64-bit wrap
        if [ "$s1" != "$s2" ]; then err "control: the two scrapes came from different JVMs (start $s1 vs $s2): a restart, or more than one replica"
        elif [ -z "$d" ]; then err "control: could not compute the delta ($b -> $a)"
        elif [ "$d" = 1 ]; then CTL_OK=1; echo "control ok: would_deny{none,index} $b -> $a in one JVM (counter is live; consistent with tenant $TEN in SHADOW, which the untagged counter cannot prove)" >&2
        elif [ "$d" = 0 ]; then SENT=zero; err "control: GET /v3 answered 200 but would_deny{none,index} stayed $b (tenant $TEN not in SHADOW, or counter not live)"
        else err "control: would_deny{none,index} moved $b -> $a, not by exactly 1 (a concurrent /v3 from another tenant?): rerun"; fi;;
      *) err "control: before/after count not readable ($(printf '%s\n' "$c1" | cut -f1)/$(printf '%s\n' "$c2" | cut -f1))";;
    esac
  fi
  # the control row is being written: an interrupt now must not add a second one, and must not be lost either
  trap 'PEND=130' INT; trap 'PEND=143' TERM; trap 'PEND=129' HUP
  if [ "$CTL_OK" = 1 ]; then row control none index 1 "this run's --control probe: would_deny{none,index} rose by exactly 1 in one JVM, consistent with +1 from this probe AFTER the counts below"
  elif [ "$SENT" = zero ]; then row control none index 0 "this run's GET /v3 answered 200 but would_deny{none,index} did not move in one JVM: the probe added nothing"
  elif [ "$SENT" = 200 ]; then row control none index 1 "this run's --control probe answered 200 (+1 AFTER the counts below if $TEN is in SHADOW) but the check failed (see stderr); the counts below are still valid"
  elif [ "$SENT" = unknown ]; then row control none index ERR "this run's GET /v3 was sent but did not answer 200: it may have added 1 AFTER the counts below; the counts below are still valid"
  else row control - - ERR "the --control check failed before GET /v3 was sent (see stderr); the counts below are still valid"; fi
  trap - INT TERM HUP
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
if [ -n "${PEND:-}" ]; then  # the signal code wins over FAIL=1; every ERROR above is still on stderr
  if [ "$WFAIL" -ne 0 ]; then echo "interrupted while the control row was written; at least one row could NOT be written to $OUTF (see the ERROR above)" >&2
  elif [ "$FAIL" -ne 0 ]; then echo "interrupted while the control row was written; every row was written, but an ERROR above also failed this run" >&2
  else echo "interrupted while the control row was written; every row was still recorded" >&2; fi
  exit "$PEND"
fi
exit $FAIL
