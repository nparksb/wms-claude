#!/usr/bin/env bash
# q.sh "<SQL>": run SQL against the DEV tenant DB only (dev_wh01_om1, via the MCP server's URI).
#
# The URI is read from ~/.claude.json and parsed. It is refused unless the host is localhost/127.0.0.1,
# the port is the dev tunnel 25060, the DB name is on the allow-list, and there are no query parameters
# (libpq params like ?host=/?port= could redirect it). The password is passed in PGPASSWORD, never argv.
# This is the fallback for when the DB MCP drops; it can WRITE, so seed carefully (see SKILL.md).
#
# Probe trap: an unqualified column inside a subquery that its own table lacks binds to the OUTER
# query, so the filter goes always-true with no error. Alias-qualify every subquery column.
set +x; set -uo pipefail
. "$(dirname "$0")/env.sh" || exit 2
SQL=${1:?usage: q.sh "<SQL>"}
PSQL=$(command -v psql || ls /usr/local/opt/libpq/bin/psql 2>/dev/null) || { echo "psql not found" >&2; exit 2; }
PARTS=$(python3 -I - "$WMS_DEV_DB_SERVER" "$WMS_DEV_DB_ALLOW" <<'EOF'
import json, os, sys, urllib.parse
want, allow = sys.argv[1], set(sys.argv[2].split(','))
d = json.load(open(os.path.expanduser('~/.claude.json')))
uri = None
def walk(o):
    global uri
    if uri: return
    if isinstance(o, dict):
        for k, v in o.items():
            if k == want and isinstance(v, dict):
                for a in v.get('args', []):
                    if isinstance(a, str) and a.startswith('postgresql:'): uri = a; return
            walk(v)
    elif isinstance(o, list):
        for x in o: walk(x)
walk(d)
if not uri: print("ERR no postgresql URI for MCP server " + want); sys.exit(1)
u = urllib.parse.urlsplit(uri)
db = u.path.lstrip('/')
if u.hostname not in ('localhost', '127.0.0.1') or u.port != 25060 or db not in allow or u.query or u.fragment:
    print(f"ERR refusing: host={u.hostname} port={u.port} db={db} query={'yes' if u.query else 'no'} is not the dev tenant DB"); sys.exit(1)
pw = urllib.parse.unquote(u.password or '')
print('\t'.join([u.hostname, str(u.port), db, urllib.parse.unquote(u.username or ''), pw]))
EOF
) || { echo "${PARTS#ERR }" >&2; exit 2; }
IFS=$'\t' read -r H PO DB U PW <<<"$PARTS"
unset PGHOSTADDR PGSERVICE PGSERVICEFILE PGHOST PGPORT PGDATABASE PGUSER PGOPTIONS PGSSLROOTCERT PGPASSFILE
PGPASSWORD=$PW PGCONNECT_TIMEOUT=10 "$PSQL" "host=$H port=$PO dbname=$DB user=$U" -qAtX -v ON_ERROR_STOP=1 -F ' | ' -c "$SQL"
