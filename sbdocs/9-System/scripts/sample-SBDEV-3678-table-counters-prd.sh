#!/bin/bash
# SBDEV-3678 PR-A before/after probe (read-only). Samples pg_stat_user_tables counters for
# fix_location_assignment, location, stockunit, unitload every 5 s.
# Usage: PSQL=/usr/bin/psql sample-SBDEV-3678-table-counters-prd.sh [samples=180] [mcp-server=wsl-wineco-prd]
# Output: ./samples-<server>-<UTC date>.txt, then: python3 analyze-SBDEV-3678-table-counters.py <file>
# The URI is read from ~/.claude.json and never printed.
P=${PSQL:-/usr/bin/psql}; N=${1:-180}; SRV=${2:-wsl-wineco-prd}; OUT=./samples-$SRV-$(date -u +%y%m%d-%H%M).txt
URI=$(SRV="$SRV" python3 -c "
import json,os
c=json.load(open(os.path.expanduser('~/.claude.json'))); srv=os.environ['SRV']
def walk(x):
  if isinstance(x,dict):
    for k,v in x.items():
      if k=='mcpServers' and srv in v:
        for a in v[srv]['args']:
          if a.startswith('postgresql:'): print(a); return True
      if walk(v): return True
walk(c)")
[ -z "$URI" ] && { echo "no postgresql: URI for $SRV in ~/.claude.json" >&2; exit 1; }
SQL="select to_char(clock_timestamp() at time zone 'UTC','HH24:MI:SS'), string_agg(relname||'='||seq_scan||'/'||seq_tup_read||'/'||idx_scan||'/'||idx_tup_fetch, ' ' order by relname) from pg_stat_user_tables where relname in ('fix_location_assignment','location','stockunit','unitload')"
for i in $(seq 1 $N); do "$P" "$URI" -qAtX -c "$SQL" >> "$OUT" || echo "sample $i failed" >&2; sleep 5; done
echo "$OUT"
