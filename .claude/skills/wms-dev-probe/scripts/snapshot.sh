#!/usr/bin/env bash
# snapshot.sh save <name> "<SELECT>" [--allow-empty] [--force] : store the result as the "before" state
# snapshot.sh diff <name>                                        : re-run it; exit 1 on ANY change
#
# The restore proof for every seeded dev test: snapshot the rows the test may touch (reservations of
# the item, replen states, unit-load locations) BEFORE seeding, then `diff` after cleanup. An empty
# diff is the only acceptable "restored", and it covers ONLY the rows your SELECT returns. Rows the test
# creates elsewhere (message / outbox rows, stockrecord history, burned sequence ids) are not covered:
# list those in the report.
#
# Each row is stored as JSON (row_to_json, which keeps duplicate column names), so NULL vs '' and separators are distinguished, and
# the lines are sorted, so row order doesn't matter. Snapshots persist in ~/.cache/wms-dev-probe/snap.
set +x; set -uo pipefail
. "$(dirname "$0")/env.sh" || exit 2
CMD=${1:?usage: snapshot.sh save|diff <name> [SELECT]}; NAME=${2:?usage}
[[ "$NAME" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { echo "name must be [A-Za-z0-9_-]{1,64}" >&2; exit 2; }
F=$SNAPDIR/$NAME
# row_to_json keeps repeated column names (s.id, u.id in a join); to_jsonb would keep only the last one.
wrap() { local q; q=$(printf '%s' "$1" | sed -E 's/;[[:space:]]*$//'); printf 'select row_to_json(t)::text from (%s) t' "$q"; }
case "$CMD" in
  save)
    SQL=${3:?usage: snapshot.sh save <name> "<SELECT>" [--allow-empty] [--force]}; shift 3
    EMPTY=0; FORCE=0
    for a in "$@"; do case "$a" in --allow-empty) EMPTY=1;; --force) FORCE=1;; *) echo "unknown $a" >&2; exit 2;; esac; done
    [ -e "$F.before" ] && [ $FORCE -eq 0 ] && { echo "snapshot '$NAME' exists; diff it first, or --force to overwrite" >&2; exit 2; }
    "$(dirname "$0")/q.sh" "$(wrap "$SQL")" | LC_ALL=C sort > "$F.tmp" || { rm -f "$F.tmp"; exit 1; }
    N=$(grep -c . "$F.tmp")
    [ "$N" -gt 0 ] || [ $EMPTY -eq 1 ] || { rm -f "$F.tmp"; echo "refusing: '$NAME' selected 0 rows, so it would prove nothing (fix the SELECT, or --allow-empty)" >&2; exit 1; }
    printf '%s' "$SQL" > "$F.sql"; mv -f "$F.tmp" "$F.before"
    echo "saved $NAME: $N row(s)";;
  diff)
    [ -f "$F.sql" ] || { echo "no snapshot '$NAME'" >&2; exit 2; }
    "$(dirname "$0")/q.sh" "$(wrap "$(cat "$F.sql")")" | LC_ALL=C sort > "$F.after" || exit 1
    if diff -u "$F.before" "$F.after"; then echo "restored: $NAME matches its snapshot ($(grep -c . "$F.before") row(s); only these rows are covered)"
    else echo "NOT restored: $NAME differs (lines above)"; exit 1; fi;;
  *) echo "usage: snapshot.sh save|diff <name> [SELECT]" >&2; exit 2;;
esac
