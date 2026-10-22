#!/usr/bin/env bash
# SBDEV-3183 AC-5: capture the SHADOW guard counters on dev, per tag combination, with the deployed version.
# Counters are JVM-local and reset on every dev deploy, so run this before deploys and at the end of the cycle.
# Output: one TSV line per (meter, domainType, function, reason-if-any) with its COUNT, appended to readings.tsv.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
api=/home/nampark/dev/wms-claude/.claude/skills/wms-dev-probe/scripts/api.sh
ts="$(date -u +%FT%TZ)"
# A run during a dev redeploy gets 502s/timeouts. Under pipefail that used to exit 1 before writing anything
# (2026-10-21, the #550 deploy), so record the gap instead of dying silently.
ver="$("$api" GET /api/public/version 2>/dev/null | head -1 | sed -E 's/.*"version":"([^"]+)".*/\1/')" || ver="(unreachable)"
for meter in wms2.authz.sdr.would_deny wms2.authz.sdr.unruled; do
  # api.sh: exit 1 = non-2xx (404 = never incremented since the last deploy), 2 = transport failure.
  rc=0; body="$("$api" GET "/actuator/metrics/$meter" 2>/dev/null | head -1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    tag="(absent)"; [ "$rc" -eq 1 ] || tag="(unreachable rc=$rc)"
    printf '%s\t%s\t%s\t-\t-\t0\t%s\n' "$ts" "$ver" "$meter" "$tag" >> "$here/readings.tsv"; continue
  fi
  types="$(python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); print(" ".join(next((t["values"] for t in d["availableTags"] if t["tag"]=="domainType"),[])))' "$body")"
  for dt in $types; do
    sub="$("$api" GET "/actuator/metrics/$meter?tag=domainType:$dt" 2>/dev/null | head -1)"
    fns="$(python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); print(" ".join(next((t["values"] for t in d["availableTags"] if t["tag"]=="function"),["-"])))' "$sub")"
    for fn in $fns; do
      q="tag=domainType:$dt"; [ "$fn" != "-" ] && q="$q&tag=function:$fn"
      c="$("$api" GET "/actuator/metrics/$meter?$q" 2>/dev/null | head -1 | python3 -I -c 'import json,sys; print(int(json.load(sys.stdin)["measurements"][0]["value"]))')" || c="(read failed)"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$ver" "$meter" "$dt" "$fn" "$c" >> "$here/readings.tsv"
    done
  done
done
tail -n 20 "$here/readings.tsv"
